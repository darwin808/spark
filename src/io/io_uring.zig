const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// io_uring-based async I/O for Linux.
pub const IoUring = struct {
    ring: linux.IoUring,
    cqes: []linux.io_uring_cqe,
    allocator: std.mem.Allocator,

    pub const Completion = struct {
        result: i32,
        user_data: u64,

        pub fn isError(self: Completion) bool {
            return self.result < 0;
        }

        pub fn errno(self: Completion) ?posix.E {
            if (self.result >= 0) return null;
            return @enumFromInt(-self.result);
        }
    };

    pub fn init(allocator: std.mem.Allocator, entries: u13) !IoUring {
        var params = std.mem.zeroes(linux.io_uring_params);

        const ring = try linux.IoUring.init(entries, &params);
        errdefer ring.deinit();

        const cqes = try allocator.alloc(linux.io_uring_cqe, entries);

        return .{
            .ring = ring,
            .cqes = cqes,
            .allocator = allocator,
        };
    }

    /// Queue an accept operation.
    pub fn queueAccept(self: *IoUring, listen_fd: posix.fd_t, user_data: u64) !void {
        _ = self.ring.accept(
            listen_fd,
            null,
            null,
            0,
            user_data,
        ) orelse return error.SubmissionQueueFull;
    }

    /// Queue a read operation.
    pub fn queueRead(self: *IoUring, fd: posix.fd_t, buffer: []u8, user_data: u64) !void {
        _ = self.ring.read(
            fd,
            .{ .buffer = buffer },
            0,
            user_data,
        ) orelse return error.SubmissionQueueFull;
    }

    /// Queue a write operation.
    pub fn queueWrite(self: *IoUring, fd: posix.fd_t, buffer: []const u8, user_data: u64) !void {
        _ = self.ring.write(
            fd,
            .{ .buffer = @constCast(buffer) },
            0,
            user_data,
        ) orelse return error.SubmissionQueueFull;
    }

    /// Queue a close operation.
    pub fn queueClose(self: *IoUring, fd: posix.fd_t, user_data: u64) !void {
        _ = self.ring.close(fd, user_data) orelse return error.SubmissionQueueFull;
    }

    /// Submit queued operations and wait for at least one completion.
    pub fn submitAndWait(self: *IoUring, wait_for: u32) ![]Completion {
        _ = try self.ring.submit_and_wait(wait_for);

        var count: usize = 0;
        while (self.ring.cq_ready() > 0 and count < self.cqes.len) {
            const cqe = self.ring.cq.head[count & (self.ring.cq.mask)];
            self.cqes[count] = cqe;
            count += 1;
            self.ring.cq.head.* +%= 1;
        }

        const completions: []Completion = @ptrCast(self.cqes[0..count]);
        for (0..count) |i| {
            completions[i] = .{
                .result = self.cqes[i].res,
                .user_data = self.cqes[i].user_data,
            };
        }

        return completions;
    }

    /// Submit queued operations without waiting.
    pub fn submit(self: *IoUring) !u32 {
        return try self.ring.submit();
    }

    pub fn deinit(self: *IoUring) void {
        self.ring.deinit();
        self.allocator.free(self.cqes);
    }
};
