const std = @import("std");
const posix = std.posix;

/// kqueue-based async I/O for macOS/BSD.
pub const Kqueue = struct {
    kq: posix.fd_t,
    events: []posix.Kevent,
    result_events: []Event,
    changelist: std.ArrayList(posix.Kevent),
    allocator: std.mem.Allocator,

    pub const Event = struct {
        fd: posix.fd_t,
        filter: Filter,
        data: isize,
        udata: usize,
        flags: u16,

        pub fn isEof(self: Event) bool {
            return (self.flags & 0x8000) != 0;
        }

        pub fn isError(self: Event) bool {
            return (self.flags & 0x4000) != 0;
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

        const result_events = try allocator.alloc(Event, max_events);
        errdefer allocator.free(result_events);

        const changelist = try std.ArrayList(posix.Kevent).initCapacity(allocator, 0);

        return .{
            .kq = kq,
            .events = events,
            .result_events = result_events,
            .changelist = changelist,
            .allocator = allocator,
        };
    }

    /// Register a file descriptor for events.
    pub fn register(self: *Kqueue, fd: posix.fd_t, filter: Filter, udata: usize) !void {
        try self.changelist.append(self.allocator, .{
            .ident = @intCast(fd),
            .filter = switch (filter) {
                .read => -1,  // EVFILT_READ
                .write => -2, // EVFILT_WRITE
            },
            .flags = 0x0001 | 0x0004, // EV_ADD | EV_ENABLE
            .fflags = 0,
            .data = 0,
            .udata = udata,
        });
    }

    /// Modify the filter for a file descriptor.
    pub fn modify(self: *Kqueue, fd: posix.fd_t, old_filter: Filter, new_filter: Filter, udata: usize) !void {
        // Delete old filter
        try self.changelist.append(self.allocator, .{
            .ident = @intCast(fd),
            .filter = switch (old_filter) {
                .read => -1,  // EVFILT_READ
                .write => -2, // EVFILT_WRITE
            },
            .flags = 0x0002, // EV_DELETE
            .fflags = 0,
            .data = 0,
            .udata = udata,
        });

        // Add new filter
        try self.register(fd, new_filter, udata);
    }

    /// Remove a file descriptor from monitoring.
    pub fn remove(self: *Kqueue, fd: posix.fd_t, filter: Filter) !void {
        try self.changelist.append(self.allocator, .{
            .ident = @intCast(fd),
            .filter = switch (filter) {
                .read => -1,  // EVFILT_READ
                .write => -2, // EVFILT_WRITE
            },
            .flags = 0x0002, // EV_DELETE
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
    }

    /// Wait for events with timeout in milliseconds.
    pub fn wait(self: *Kqueue, timeout_ms: ?u32) ![]Event {
        const timeout: ?posix.timespec = if (timeout_ms) |ms| .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        const n = posix.kevent(
            self.kq,
            self.changelist.items,
            self.events,
            if (timeout) |*t| t else null,
        ) catch return &.{};

        self.changelist.clearRetainingCapacity();

        // Convert to our Event type
        for (self.events[0..n], 0..) |ev, i| {
            self.result_events[i] = .{
                .fd = @intCast(ev.ident),
                .filter = if (ev.filter == -1) .read else .write, // -1 = EVFILT_READ
                .data = ev.data,
                .udata = ev.udata,
                .flags = ev.flags,
            };
        }

        return self.result_events[0..n];
    }

    pub fn deinit(self: *Kqueue) void {
        posix.close(self.kq);
        self.allocator.free(self.events);
        self.allocator.free(self.result_events);
        self.changelist.deinit(self.allocator);
    }
};
