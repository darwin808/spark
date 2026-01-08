const std = @import("std");
const builtin = @import("builtin");

const KqueueWatcher = @import("kqueue_watcher.zig").KqueueWatcher;
const InotifyWatcher = @import("inotify_watcher.zig").InotifyWatcher;

/// Cross-platform file system watcher.
/// Uses kqueue on macOS/BSD and inotify on Linux.
pub const FileWatcher = struct {
    backend: Backend,
    allocator: std.mem.Allocator,

    const is_bsd = builtin.os.tag == .macos or builtin.os.tag == .freebsd or
        builtin.os.tag == .netbsd or builtin.os.tag == .openbsd;
    const is_linux = builtin.os.tag == .linux;

    const Backend = if (is_bsd)
        KqueueWatcher
    else if (is_linux)
        InotifyWatcher
    else
        @compileError("Hot reload requires macOS, BSD, or Linux");

    pub const Event = struct {
        path: []const u8,
        kind: Kind,

        pub const Kind = enum {
            modified,
            created,
            deleted,
            renamed,
        };
    };

    pub const Error = Backend.Error;

    pub fn init(allocator: std.mem.Allocator) Error!FileWatcher {
        return .{
            .backend = try Backend.init(allocator),
            .allocator = allocator,
        };
    }

    /// Watch a directory for changes.
    pub fn watchDir(self: *FileWatcher, path: []const u8) Error!void {
        try self.backend.watchDir(path);
    }

    /// Unwatch a directory.
    pub fn unwatchDir(self: *FileWatcher, path: []const u8) void {
        self.backend.unwatchDir(path);
    }

    /// Poll for file system events.
    /// timeout_ms: null for blocking, 0 for non-blocking, >0 for timeout
    /// Returns slice of unified events - caller must call freeEvents().
    pub fn poll(self: *FileWatcher, timeout_ms: ?u32) Error![]Event {
        const backend_events = try self.backend.poll(timeout_ms);
        defer self.backend.freeEvents(backend_events);

        if (backend_events.len == 0) return &.{};

        var results = std.ArrayList(Event){};
        errdefer {
            for (results.items) |e| self.allocator.free(e.path);
            results.deinit(self.allocator);
        }

        for (backend_events) |ev| {
            const kind: Event.Kind = if (is_bsd) blk: {
                if (ev.isDelete()) break :blk .deleted;
                if (ev.isRename()) break :blk .renamed;
                break :blk .modified;
            } else blk: {
                if (ev.isDelete()) break :blk .deleted;
                if (ev.isCreate()) break :blk .created;
                if (ev.isMove()) break :blk .renamed;
                break :blk .modified;
            };

            // For inotify, construct full path from dir + name
            const full_path = if (is_linux and ev.name != null)
                try std.fs.path.join(self.allocator, &.{ ev.dir_path, ev.name.? })
            else
                try self.allocator.dupe(u8, ev.dir_path);

            try results.append(self.allocator, .{
                .path = full_path,
                .kind = kind,
            });
        }

        return results.toOwnedSlice(self.allocator) catch return &.{};
    }

    /// Free events returned by poll().
    pub fn freeEvents(self: *FileWatcher, events: []Event) void {
        for (events) |ev| {
            self.allocator.free(ev.path);
        }
        self.allocator.free(events);
    }

    pub fn deinit(self: *FileWatcher) void {
        self.backend.deinit();
    }
};
