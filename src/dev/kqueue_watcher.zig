const std = @import("std");
const posix = std.posix;

/// macOS/BSD file system watcher using kqueue with EVFILT_VNODE.
/// Watches directories for file changes.
pub const KqueueWatcher = struct {
    kq: posix.fd_t,
    watched: std.ArrayList(WatchedDir),
    events: []posix.Kevent,
    allocator: std.mem.Allocator,

    const WatchedDir = struct {
        fd: posix.fd_t,
        path: []const u8,
    };

    // kqueue constants
    const EVFILT_VNODE: i16 = -4;
    const EV_ADD: u16 = 0x0001;
    const EV_ENABLE: u16 = 0x0004;
    const EV_CLEAR: u16 = 0x0020;

    // vnode event flags
    const NOTE_DELETE: u32 = 0x0001;
    const NOTE_WRITE: u32 = 0x0002;
    const NOTE_EXTEND: u32 = 0x0004;
    const NOTE_ATTRIB: u32 = 0x0008;
    const NOTE_LINK: u32 = 0x0010;
    const NOTE_RENAME: u32 = 0x0020;
    const NOTE_REVOKE: u32 = 0x0040;

    const NOTE_ALL: u32 = NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_RENAME;

    pub const Event = struct {
        dir_path: []const u8,
        flags: u32,

        pub fn isWrite(self: Event) bool {
            return (self.flags & NOTE_WRITE) != 0 or (self.flags & NOTE_EXTEND) != 0;
        }

        pub fn isDelete(self: Event) bool {
            return (self.flags & NOTE_DELETE) != 0;
        }

        pub fn isRename(self: Event) bool {
            return (self.flags & NOTE_RENAME) != 0;
        }
    };

    pub const Error = error{
        KqueueCreateFailed,
        WatchFailed,
        PollFailed,
    } || posix.OpenError || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator) Error!KqueueWatcher {
        const kq = posix.kqueue() catch return error.KqueueCreateFailed;

        const events = try allocator.alloc(posix.Kevent, 64);

        return .{
            .kq = kq,
            .watched = std.ArrayList(WatchedDir){},
            .events = events,
            .allocator = allocator,
        };
    }

    /// Watch a directory for changes.
    pub fn watchDir(self: *KqueueWatcher, path: []const u8) Error!void {
        // Check if already watching this path
        for (self.watched.items) |w| {
            if (std.mem.eql(u8, w.path, path)) return;
        }

        // Open directory for watching (O_EVTONLY is macOS-specific for event-only fd)
        const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);

        // First add to watched list
        const path_copy = try self.allocator.dupe(u8, path);
        try self.watched.append(self.allocator, .{ .fd = fd, .path = path_copy });

        // Register with kqueue
        var changelist = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = NOTE_ALL,
            .data = 0,
            .udata = self.watched.items.len - 1,
        }};

        const result = posix.kevent(self.kq, &changelist, &.{}, null) catch {
            return error.WatchFailed;
        };
        _ = result;
    }

    /// Unwatch a directory.
    pub fn unwatchDir(self: *KqueueWatcher, path: []const u8) void {
        for (self.watched.items, 0..) |w, i| {
            if (std.mem.eql(u8, w.path, path)) {
                posix.close(w.fd);
                self.allocator.free(w.path);
                _ = self.watched.swapRemove(i);
                return;
            }
        }
    }

    /// Poll for events. Returns slice of events that occurred.
    /// timeout_ms: null for blocking, 0 for non-blocking, >0 for timeout
    pub fn poll(self: *KqueueWatcher, timeout_ms: ?u32) Error![]Event {
        const timeout: ?posix.timespec = if (timeout_ms) |ms| .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        const count = posix.kevent(self.kq, &.{}, self.events, if (timeout) |*t| t else null) catch {
            return error.PollFailed;
        };

        // Convert kernel events to our Event type
        var results = std.ArrayList(Event){};

        for (self.events[0..count]) |ev| {
            const idx = ev.udata;
            if (idx < self.watched.items.len) {
                results.append(self.allocator, .{
                    .dir_path = self.watched.items[idx].path,
                    .flags = ev.fflags,
                }) catch continue;
            }
        }

        // Return owned slice
        return results.toOwnedSlice(self.allocator) catch return &.{};
    }

    /// Free events returned by poll()
    pub fn freeEvents(self: *KqueueWatcher, events: []Event) void {
        self.allocator.free(events);
    }

    pub fn deinit(self: *KqueueWatcher) void {
        for (self.watched.items) |w| {
            posix.close(w.fd);
            self.allocator.free(w.path);
        }
        self.watched.deinit(self.allocator);
        self.allocator.free(self.events);
        posix.close(self.kq);
    }
};
