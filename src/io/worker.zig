const std = @import("std");
const posix = std.posix;
const Io = @import("io.zig").Io;

/// Worker manages a single event loop thread.
/// Each worker has its own socket (via SO_REUSEPORT), Io instance, and thread.
pub const Worker = struct {
    thread: ?std.Thread = null,
    io: ?Io = null,
    listen_fd: posix.fd_t = -1,
    id: usize,
    running: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    // Thread context passed to spawned thread
    const ThreadContext = struct {
        worker: *Worker,
        handler: *const fn (*Io.Connection) void,
        context: ?*anyopaque,
    };

    pub const Config = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 3000,
        io_config: Io.Config = .{},
    };

    /// Initialize a worker (does not start the thread).
    pub fn init(
        id: usize,
        running: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
    ) Worker {
        return .{
            .id = id,
            .running = running,
            .allocator = allocator,
        };
    }

    /// Start the worker thread.
    pub fn start(
        self: *Worker,
        config: Config,
        handler: *const fn (*Io.Connection) void,
        context: ?*anyopaque,
    ) !void {
        // Create Io instance with shared running flag
        self.io = try Io.initShared(self.allocator, config.io_config, self.running);
        errdefer {
            if (self.io) |*io| io.deinit();
            self.io = null;
        }

        // Create listening socket (SO_REUSEPORT allows multiple sockets on same port)
        self.listen_fd = try self.io.?.listen(config.host, config.port);
        errdefer {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }

        // Spawn thread
        const thread_ctx = ThreadContext{
            .worker = self,
            .handler = handler,
            .context = context,
        };

        self.thread = try std.Thread.spawn(.{}, threadMain, .{thread_ctx});
    }

    fn threadMain(ctx: ThreadContext) void {
        const self = ctx.worker;

        // Run the event loop
        self.io.?.run(self.listen_fd, ctx.handler, ctx.context) catch |err| {
            std.log.err("Worker {d} error: {}", .{ self.id, err });
        };
    }

    /// Wait for the worker thread to finish.
    pub fn join(self: *Worker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Clean up worker resources.
    pub fn deinit(self: *Worker) void {
        // Ensure thread is joined first
        self.join();

        // Close listen socket
        if (self.listen_fd != -1) {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }

        // Clean up Io
        if (self.io) |*io| {
            io.deinit();
            self.io = null;
        }
    }
};
