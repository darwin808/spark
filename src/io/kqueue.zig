const std = @import("std");
const posix = std.posix;

/// kqueue-based async I/O for macOS/BSD.
pub const Kqueue = struct {
    kq: posix.fd_t,
    events: []posix.Kevent,
    changelist: std.ArrayList(posix.Kevent),

    pub const Event = struct {
        fd: posix.fd_t,
        filter: Filter,
        data: isize,
        udata: usize,
        flags: u16,

        pub fn isEof(self: Event) bool {
            return (self.flags & posix.system.EV_EOF) != 0;
        }

        pub fn isError(self: Event) bool {
            return (self.flags & posix.system.EV_ERROR) != 0;
        }
    };

    pub const Filter = enum {
        read,
        write,
    };

    pub fn init(allocator: std.mem.Allocator, max_events: usize) !Kqueue {
        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        const events = try allocator.alloc(posix.Kevent, max_events);
        errdefer allocator.free(events);

        return .{
            .kq = kq,
            .events = events,
            .changelist = std.ArrayList(posix.Kevent).init(allocator),
        };
    }

    /// Register a file descriptor for events.
    pub fn register(self: *Kqueue, fd: posix.fd_t, filter: Filter, udata: usize) !void {
        try self.changelist.append(.{
            .ident = @intCast(fd),
            .filter = switch (filter) {
                .read => posix.system.EVFILT_READ,
                .write => posix.system.EVFILT_WRITE,
            },
            .flags = posix.system.EV_ADD | posix.system.EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        });
    }

    /// Modify the filter for a file descriptor.
    pub fn modify(self: *Kqueue, fd: posix.fd_t, old_filter: Filter, new_filter: Filter, udata: usize) !void {
        // Delete old filter
        try self.changelist.append(.{
            .ident = @intCast(fd),
            .filter = switch (old_filter) {
                .read => posix.system.EVFILT_READ,
                .write => posix.system.EVFILT_WRITE,
            },
            .flags = posix.system.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        });

        // Add new filter
        try self.register(fd, new_filter, udata);
    }

    /// Remove a file descriptor from monitoring.
    pub fn remove(self: *Kqueue, fd: posix.fd_t, filter: Filter) !void {
        try self.changelist.append(.{
            .ident = @intCast(fd),
            .filter = switch (filter) {
                .read => posix.system.EVFILT_READ,
                .write => posix.system.EVFILT_WRITE,
            },
            .flags = posix.system.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
    }

    /// Wait for events with timeout in milliseconds.
    pub fn wait(self: *Kqueue, timeout_ms: ?u32) ![]Event {
        const timeout: ?posix.timespec = if (timeout_ms) |ms| .{
            .tv_sec = @intCast(ms / 1000),
            .tv_nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        const n = posix.kevent(
            self.kq,
            self.changelist.items,
            self.events,
            if (timeout) |*t| t else null,
        ) catch |err| switch (err) {
            error.Interrupted => return &.{},
            else => return err,
        };

        self.changelist.clearRetainingCapacity();

        // Convert to our Event type
        const result: []Event = @ptrCast(self.events[0..n]);
        for (self.events[0..n], 0..) |ev, i| {
            result[i] = .{
                .fd = @intCast(ev.ident),
                .filter = if (ev.filter == posix.system.EVFILT_READ) .read else .write,
                .data = ev.data,
                .udata = ev.udata,
                .flags = ev.flags,
            };
        }

        return result;
    }

    pub fn deinit(self: *Kqueue) void {
        posix.close(self.kq);
        self.changelist.allocator.free(self.events);
        self.changelist.deinit();
    }
};
