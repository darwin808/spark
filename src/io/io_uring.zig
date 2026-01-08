const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// io_uring-based async I/O for Linux.
pub const IoUring = struct {
    ring: linux.IoUring,
    cqes: []linux.io_uring_cqe,
    allocator: std.mem.Allocator,
    config: Config,
    // Registered resources
    registered_buffers: ?[]posix.iovec = null,
    registered_files: ?[]posix.fd_t = null,

    pub const Config = struct {
        entries: u13 = 4096,
        /// Enable SQPOLL mode (kernel thread polls submission queue).
        /// May require elevated privileges (CAP_SYS_NICE or root).
        sqpoll: bool = false,
        /// Idle timeout in ms before SQPOLL thread sleeps.
        sqpoll_idle_ms: u32 = 1000,
    };

    pub const Completion = struct {
        result: i32,
        user_data: u64,
        flags: u32,

        pub fn isError(self: Completion) bool {
            return self.result < 0;
        }

        pub fn errno(self: Completion) ?posix.E {
            if (self.result >= 0) return null;
            return @enumFromInt(-self.result);
        }

        /// Check if more completions are coming (for multishot operations).
        pub fn hasMore(self: Completion) bool {
            return (self.flags & linux.IORING_CQE_F_MORE) != 0;
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !IoUring {
        var params = std.mem.zeroes(linux.io_uring_params);

        // Enable SQPOLL if requested
        if (config.sqpoll) {
            params.flags |= linux.IORING_SETUP_SQPOLL;
            params.sq_thread_idle = config.sqpoll_idle_ms;
        }

        const ring = linux.IoUring.init(config.entries, &params) catch |err| {
            // If SQPOLL fails (permission denied), try without it
            if (config.sqpoll and err == error.PermissionDenied) {
                std.log.warn("SQPOLL mode requires elevated privileges, falling back to standard mode", .{});
                var fallback_params = std.mem.zeroes(linux.io_uring_params);
                const fallback_ring = try linux.IoUring.init(config.entries, &fallback_params);
                const cqes = try allocator.alloc(linux.io_uring_cqe, config.entries);
                return .{
                    .ring = fallback_ring,
                    .cqes = cqes,
                    .allocator = allocator,
                    .config = .{
                        .entries = config.entries,
                        .sqpoll = false, // Mark as disabled
                        .sqpoll_idle_ms = config.sqpoll_idle_ms,
                    },
                };
            }
            return err;
        };
        errdefer ring.deinit();

        const cqes = try allocator.alloc(linux.io_uring_cqe, config.entries);

        return .{
            .ring = ring,
            .cqes = cqes,
            .allocator = allocator,
            .config = config,
        };
    }

    // ========================================
    // Standard Operations
    // ========================================

    /// Queue an accept operation (single-shot).
    pub fn queueAccept(self: *IoUring, listen_fd: posix.fd_t, user_data: u64) !void {
        _ = self.ring.accept(
            listen_fd,
            null,
            null,
            0,
            user_data,
        ) orelse return error.SubmissionQueueFull;
    }

    /// Queue a multishot accept operation.
    /// A single SQE will produce multiple CQEs as connections arrive.
    /// Check Completion.hasMore() - if false, the multishot was cancelled.
    pub fn queueMultishotAccept(self: *IoUring, listen_fd: posix.fd_t, user_data: u64) !void {
        _ = self.ring.accept(
            listen_fd,
            null,
            null,
            linux.IORING_ACCEPT_MULTISHOT,
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

    // ========================================
    // Registered Buffers (Fixed Buffers)
    // ========================================

    /// Register buffers with the kernel for zero-copy I/O.
    /// Buffers must remain valid until unregistered or ring is closed.
    pub fn registerBuffers(self: *IoUring, iovecs: []posix.iovec) !void {
        try self.ring.register_buffers(iovecs);
        self.registered_buffers = iovecs;
    }

    /// Unregister previously registered buffers.
    pub fn unregisterBuffers(self: *IoUring) !void {
        if (self.registered_buffers != null) {
            try self.ring.unregister_buffers();
            self.registered_buffers = null;
        }
    }

    /// Queue a read using a registered (fixed) buffer.
    /// buf_index is the index into the registered buffer array.
    pub fn queueReadFixed(
        self: *IoUring,
        fd: posix.fd_t,
        buffer: []u8,
        buf_index: u16,
        user_data: u64,
    ) !void {
        _ = self.ring.read(
            fd,
            .{ .buffer = buffer, .buffer_selection = .{ .buffer_index = buf_index } },
            0,
            user_data,
        ) orelse return error.SubmissionQueueFull;
    }

    /// Queue a write using a registered (fixed) buffer.
    pub fn queueWriteFixed(
        self: *IoUring,
        fd: posix.fd_t,
        buffer: []const u8,
        buf_index: u16,
        user_data: u64,
    ) !void {
        _ = self.ring.write(
            fd,
            .{ .buffer = @constCast(buffer), .buffer_selection = .{ .buffer_index = buf_index } },
            0,
            user_data,
        ) orelse return error.SubmissionQueueFull;
    }

    // ========================================
    // Registered Files (Fixed Files)
    // ========================================

    /// Register file descriptors for direct access.
    /// Use registerFilesUpdate() to add new FDs to slots.
    pub fn registerFiles(self: *IoUring, fds: []posix.fd_t) !void {
        try self.ring.register_files(fds);
        self.registered_files = fds;
    }

    /// Update a registered file slot with a new FD.
    /// Set fd to -1 to clear the slot.
    pub fn updateRegisteredFile(self: *IoUring, index: u32, fd: posix.fd_t) !void {
        try self.ring.register_files_update(index, &[_]posix.fd_t{fd});
        if (self.registered_files) |files| {
            if (index < files.len) {
                files[index] = fd;
            }
        }
    }

    /// Unregister previously registered files.
    pub fn unregisterFiles(self: *IoUring) !void {
        if (self.registered_files != null) {
            try self.ring.unregister_files();
            self.registered_files = null;
        }
    }

    // ========================================
    // Submission and Completion
    // ========================================

    /// Submit queued operations and wait for at least one completion.
    pub fn submitAndWait(self: *IoUring, wait_for: u32) ![]Completion {
        _ = try self.ring.submit_and_wait(wait_for);
        return self.reapCompletions();
    }

    /// Submit queued operations without waiting.
    pub fn submit(self: *IoUring) !u32 {
        return try self.ring.submit();
    }

    /// Reap available completions without submitting.
    pub fn reapCompletions(self: *IoUring) []Completion {
        var count: usize = 0;
        while (self.ring.cq_ready() > 0 and count < self.cqes.len) {
            const cqe = self.ring.cq.head[count & (self.ring.cq.mask)];
            self.cqes[count] = cqe;
            count += 1;
            self.ring.cq.head.* +%= 1;
        }

        // Convert CQEs to Completions in-place
        const completions: []Completion = @ptrCast(self.cqes[0..count]);
        for (0..count) |i| {
            completions[i] = .{
                .result = self.cqes[i].res,
                .user_data = self.cqes[i].user_data,
                .flags = self.cqes[i].flags,
            };
        }

        return completions;
    }

    /// Check if there are pending completions.
    pub fn hasCompletions(self: *IoUring) bool {
        return self.ring.cq_ready() > 0;
    }

    /// Get the number of ready completions.
    pub fn completionsReady(self: *IoUring) u32 {
        return self.ring.cq_ready();
    }

    pub fn deinit(self: *IoUring) void {
        // Unregister resources before closing the ring
        self.unregisterBuffers() catch {};
        self.unregisterFiles() catch {};
        self.ring.deinit();
        self.allocator.free(self.cqes);
    }
};
