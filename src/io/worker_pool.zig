const std = @import("std");
const Worker = @import("worker.zig").Worker;
const Io = @import("io.zig").Io;

/// WorkerPool manages multiple worker threads for multi-core execution.
/// Uses SO_REUSEPORT to allow the kernel to load-balance connections.
pub const WorkerPool = struct {
    workers: []Worker,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    num_workers: usize,

    pub const Config = struct {
        num_workers: ?usize = null, // null = auto-detect CPU count
        host: []const u8 = "127.0.0.1",
        port: u16 = 3000,
        io_config: Io.Config = .{},
    };

    /// Initialize the worker pool.
    /// Note: Workers' running pointers are set in start() to avoid dangling pointer
    /// issues when the pool is returned by value.
    pub fn init(allocator: std.mem.Allocator, config: Config) !WorkerPool {
        const num_workers = config.num_workers orelse detectCpuCount();

        const workers = try allocator.alloc(Worker, num_workers);
        errdefer allocator.free(workers);

        // Initialize workers with placeholder values - running pointer set in start()
        for (workers, 0..) |*w, i| {
            w.* = Worker{
                .id = i,
                .running = undefined, // Will be set in start()
                .allocator = allocator,
            };
        }

        return WorkerPool{
            .workers = workers,
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .num_workers = num_workers,
        };
    }

    /// Detect the number of CPU cores.
    fn detectCpuCount() usize {
        return std.Thread.getCpuCount() catch 1;
    }

    /// Start all workers and block until shutdown.
    pub fn start(
        self: *WorkerPool,
        config: Config,
        handler: *const fn (*Io.Connection) void,
        context: ?*anyopaque,
    ) !void {
        self.running.store(true, .release);

        // Set running pointer on all workers now that pool is in its final location
        for (self.workers) |*w| {
            w.running = &self.running;
        }

        // Divide connections across workers
        const per_worker_connections = config.io_config.max_connections / self.num_workers;
        var worker_io_config = config.io_config;
        worker_io_config.max_connections = @max(per_worker_connections, 100);

        const worker_config = Worker.Config{
            .host = config.host,
            .port = config.port,
            .io_config = worker_io_config,
        };

        // Start all worker threads
        var started: usize = 0;
        errdefer {
            // On error, stop and clean up started workers
            self.running.store(false, .release);
            for (self.workers[0..started]) |*w| {
                w.join();
                w.deinit();
            }
        }

        for (self.workers) |*w| {
            try w.start(worker_config, handler, context);
            started += 1;
        }

        std.log.info("Started {d} worker threads", .{self.num_workers});
    }

    /// Wait for all workers to complete.
    pub fn join(self: *WorkerPool) void {
        for (self.workers) |*w| {
            w.join();
        }
    }

    /// Signal all workers to stop.
    pub fn stop(self: *WorkerPool) void {
        self.running.store(false, .release);
    }

    /// Stop and wait for all workers.
    pub fn shutdown(self: *WorkerPool) void {
        self.stop();
        self.join();
    }

    /// Clean up all resources.
    pub fn deinit(self: *WorkerPool) void {
        for (self.workers) |*w| {
            w.deinit();
        }
        self.allocator.free(self.workers);
    }
};
