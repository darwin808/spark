const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Linux file system watcher using inotify.
pub const InotifyWatcher = struct {
    fd: posix.fd_t,
    watch_descriptors: std.AutoHashMap(i32, []const u8),
    buffer: [4096]u8,
    allocator: std.mem.Allocator,

    pub const Event = struct {
        dir_path: []const u8,
        name: ?[]const u8,
        mask: u32,

        pub fn isWrite(self: Event) bool {
            return (self.mask & linux.IN.MODIFY) != 0;
        }

        pub fn isCreate(self: Event) bool {
            return (self.mask & linux.IN.CREATE) != 0;
        }

        pub fn isDelete(self: Event) bool {
            return (self.mask & linux.IN.DELETE) != 0;
        }

        pub fn isMove(self: Event) bool {
            return (self.mask & (linux.IN.MOVED_FROM | linux.IN.MOVED_TO)) != 0;
        }
    };

    pub const Error = error{
        InotifyInitFailed,
        WatchFailed,
        PollFailed,
    } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator) Error!InotifyWatcher {
        const fd = linux.inotify_init1(linux.IN.NONBLOCK);
        if (@as(isize, @bitCast(fd)) < 0) {
            return error.InotifyInitFailed;
        }

        return .{
            .fd = @intCast(fd),
            .watch_descriptors = std.AutoHashMap(i32, []const u8).init(allocator),
            .buffer = undefined,
            .allocator = allocator,
        };
    }

    /// Watch a directory for changes.
    pub fn watchDir(self: *InotifyWatcher, path: []const u8) Error!void {
        // Check if already watching
        var iter = self.watch_descriptors.valueIterator();
        while (iter.next()) |existing| {
            if (std.mem.eql(u8, existing.*, path)) return;
        }

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
            linux.IN.MOVED_FROM | linux.IN.MOVED_TO;

        const wd = linux.inotify_add_watch(self.fd, path_z, mask);
        if (@as(isize, @bitCast(wd)) < 0) {
            return error.WatchFailed;
        }

        const path_copy = try self.allocator.dupe(u8, path);
        try self.watch_descriptors.put(@intCast(wd), path_copy);
    }

    /// Unwatch a directory.
    pub fn unwatchDir(self: *InotifyWatcher, path: []const u8) void {
        var to_remove: ?i32 = null;
        var iter = self.watch_descriptors.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, path)) {
                to_remove = entry.key_ptr.*;
                break;
            }
        }

        if (to_remove) |wd| {
            _ = linux.inotify_rm_watch(self.fd, wd);
            if (self.watch_descriptors.fetchRemove(wd)) |kv| {
                self.allocator.free(kv.value);
            }
        }
    }

    /// Poll for events. Returns slice of events that occurred.
    pub fn poll(self: *InotifyWatcher, timeout_ms: ?u32) Error![]Event {
        // Use poll() to check if data is available
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const timeout: i32 = if (timeout_ms) |ms| @intCast(ms) else -1;
        const poll_result = posix.poll(&pfd, timeout) catch return error.PollFailed;

        if (poll_result == 0 or (pfd[0].revents & posix.POLL.IN) == 0) {
            return &.{};
        }

        // Read events
        const bytes_read = posix.read(self.fd, &self.buffer) catch return error.PollFailed;
        if (bytes_read == 0) return &.{};

        var results = std.ArrayList(Event){};
        defer results.deinit(self.allocator);

        var offset: usize = 0;
        while (offset < bytes_read) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&self.buffer[offset]));

            if (self.watch_descriptors.get(event.wd)) |dir_path| {
                const name: ?[]const u8 = if (event.len > 0)
                    std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.buffer[offset + @sizeOf(linux.inotify_event)])), 0)
                else
                    null;

                results.append(self.allocator, .{
                    .dir_path = dir_path,
                    .name = name,
                    .mask = event.mask,
                }) catch continue;
            }

            offset += @sizeOf(linux.inotify_event) + event.len;
        }

        return results.toOwnedSlice(self.allocator) catch return &.{};
    }

    /// Free events returned by poll()
    pub fn freeEvents(self: *InotifyWatcher, events: []Event) void {
        self.allocator.free(events);
    }

    pub fn deinit(self: *InotifyWatcher) void {
        var iter = self.watch_descriptors.valueIterator();
        while (iter.next()) |path| {
            self.allocator.free(path.*);
        }
        self.watch_descriptors.deinit();
        posix.close(self.fd);
    }
};
