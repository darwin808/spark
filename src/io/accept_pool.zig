const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Io = @import("io.zig").Io;
const FdQueue = @import("fd_queue.zig").FdQueue;
const FdDistributor = @import("fd_queue.zig").FdDistributor;
const BufferPool = @import("buffer_pool.zig").BufferPool;

const Kqueue = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) @import("kqueue.zig").Kqueue else void;

/// AcceptPool: Single acceptor thread + multiple worker threads.
/// Solves SO_REUSEPORT load balancing issues on macOS.
pub const AcceptPool = struct {
    workers: []Worker,
    queues: []FdQueue,
    queue_ptrs: []*FdQueue,
    distributor: FdDistributor,
    running: std.atomic.Value(bool),
    acceptor_thread: ?std.Thread = null,
    listen_fd: posix.fd_t = -1,
    allocator: std.mem.Allocator,
    handler: ?*const fn (*Io.Connection) void = null,
    handler_context: ?*anyopaque = null,
    config: Config,

    pub const Config = struct {
        num_workers: ?usize = null, // null = auto-detect
        host: []const u8 = "127.0.0.1",
        port: u16 = 3000,
        max_connections: usize = 10000,
        buffer_size: usize = 16 * 1024,
        queue_size: usize = 1024, // FDs per worker queue
    };

    const Worker = struct {
        id: usize,
        thread: ?std.Thread = null,
        io: ?WorkerIo = null,
        queue: *FdQueue,
        running: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        handler: *const fn (*Io.Connection) void,
        handler_context: ?*anyopaque,
        config: WorkerConfig,

        const WorkerConfig = struct {
            max_connections: usize,
            buffer_size: usize,
        };

        fn start(self: *Worker) !void {
            self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        }

        fn workerMain(self: *Worker) void {
            // Initialize worker's own I/O (kqueue/io_uring)
            self.io = WorkerIo.init(self.allocator, self.config) catch |err| {
                std.log.err("Worker {d} init failed: {}", .{ self.id, err });
                return;
            };

            while (self.running.load(.acquire)) {
                // Check for new connections from queue (non-blocking)
                while (self.io.?.canAcceptMore()) {
                    if (self.queue.tryPop()) |fd| {
                        self.io.?.addConnection(fd, self.handler_context) catch |err| {
                            std.log.warn("Worker {d} add connection failed: {}", .{ self.id, err });
                            posix.close(fd);
                        };
                    } else {
                        break;
                    }
                }

                // Process events
                self.io.?.poll(self.handler) catch |err| {
                    std.log.warn("Worker {d} poll error: {}", .{ self.id, err });
                };
            }

            if (self.io) |*io| io.deinit();
        }

        fn join(self: *Worker) void {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }
    };

    /// Per-worker I/O handling (simplified, kqueue-focused for now)
    const WorkerIo = struct {
        kq: Kqueue,
        connections: ConnectionPool,
        buffer_pool: BufferPool,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, config: Worker.WorkerConfig) !WorkerIo {
            return .{
                .kq = try Kqueue.init(allocator, 256),
                .connections = try ConnectionPool.init(allocator, config.max_connections),
                .buffer_pool = try BufferPool.init(allocator, config.max_connections * 2, config.buffer_size),
                .allocator = allocator,
            };
        }

        fn deinit(self: *WorkerIo) void {
            self.kq.deinit();
            self.connections.deinit();
            self.buffer_pool.deinit();
        }

        fn canAcceptMore(self: *WorkerIo) bool {
            return self.connections.available() > 0;
        }

        fn addConnection(self: *WorkerIo, fd: posix.fd_t, context: ?*anyopaque) !void {
            const conn = self.connections.acquire() orelse return error.PoolExhausted;
            errdefer self.connections.release(conn);

            conn.fd = fd;
            conn.context = context;
            conn.state = .idle;

            // Get buffers
            const read_buf = self.buffer_pool.acquire() orelse return error.BufferExhausted;
            errdefer self.buffer_pool.release(read_buf);
            const write_buf = self.buffer_pool.acquire() orelse return error.BufferExhausted;

            conn.read_buffer = read_buf.data;
            conn.write_buffer = write_buf.data;
            conn.reset();

            try self.kq.register(fd, .read, conn.index);
        }

        fn poll(self: *WorkerIo, handler: *const fn (*Io.Connection) void) !void {
            const events = try self.kq.wait(1); // 1ms timeout for responsiveness

            for (events) |ev| {
                const conn = self.connections.get(ev.udata) orelse continue;

                if (ev.isEof() or ev.isError()) {
                    self.closeConnection(conn);
                    continue;
                }

                switch (ev.filter) {
                    .read => {
                        const n = posix.read(conn.fd, conn.readSlice()) catch {
                            self.closeConnection(conn);
                            continue;
                        };

                        if (n == 0) {
                            self.closeConnection(conn);
                            continue;
                        }

                        conn.read_pos += n;
                        conn.state = .reading;

                        handler(conn);

                        if (conn.write_len > 0) {
                            conn.state = .writing;
                            self.kq.modify(conn.fd, .read, .write, conn.index) catch {
                                self.closeConnection(conn);
                            };
                        }
                    },
                    .write => {
                        const remaining = conn.write_buffer[conn.write_pos..conn.write_len];
                        const n = posix.write(conn.fd, remaining) catch {
                            self.closeConnection(conn);
                            continue;
                        };

                        conn.write_pos += n;

                        if (conn.write_pos >= conn.write_len) {
                            conn.reset();
                            self.kq.modify(conn.fd, .write, .read, conn.index) catch {
                                self.closeConnection(conn);
                            };
                        }
                    },
                }
            }
        }

        fn closeConnection(self: *WorkerIo, conn: *Io.Connection) void {
            if (conn.state == .closed) return;
            conn.state = .closed;
            self.kq.remove(conn.fd, .read) catch {};
            self.kq.remove(conn.fd, .write) catch {};
            posix.close(conn.fd);
            self.connections.release(conn);
        }
    };

    const ConnectionPool = struct {
        connections: []Io.Connection,
        free_list: std.ArrayList(usize),
        free_count: std.atomic.Value(usize),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, max: usize) !ConnectionPool {
            const conns = try allocator.alloc(Io.Connection, max);
            for (conns, 0..) |*c, i| {
                c.index = i;
                c.state = .closed;
            }

            var free = try std.ArrayList(usize).initCapacity(allocator, max);
            for (0..max) |i| {
                free.appendAssumeCapacity(max - 1 - i);
            }

            return .{
                .connections = conns,
                .free_list = free,
                .free_count = std.atomic.Value(usize).init(max),
                .allocator = allocator,
            };
        }

        fn deinit(self: *ConnectionPool) void {
            self.allocator.free(self.connections);
            self.free_list.deinit(self.allocator);
        }

        fn available(self: *ConnectionPool) usize {
            return self.free_count.load(.acquire);
        }

        fn acquire(self: *ConnectionPool) ?*Io.Connection {
            const idx = self.free_list.pop() orelse return null;
            _ = self.free_count.fetchSub(1, .release);
            return &self.connections[idx];
        }

        fn get(self: *ConnectionPool, idx: usize) ?*Io.Connection {
            if (idx >= self.connections.len) return null;
            const conn = &self.connections[idx];
            if (conn.state == .closed) return null;
            return conn;
        }

        fn release(self: *ConnectionPool, conn: *Io.Connection) void {
            self.free_list.append(self.allocator, conn.index) catch {};
            _ = self.free_count.fetchAdd(1, .release);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !AcceptPool {
        const num_workers = config.num_workers orelse (std.Thread.getCpuCount() catch 1);
        const per_worker_conns = config.max_connections / num_workers;

        // Allocate workers and queues
        const workers = try allocator.alloc(Worker, num_workers);
        errdefer allocator.free(workers);

        const queues = try allocator.alloc(FdQueue, num_workers);
        errdefer allocator.free(queues);

        const queue_ptrs = try allocator.alloc(*FdQueue, num_workers);
        errdefer allocator.free(queue_ptrs);

        // Initialize queues
        for (queues, 0..) |*q, i| {
            q.* = try FdQueue.init(allocator, config.queue_size);
            queue_ptrs[i] = q;
        }

        // Initialize workers (threads not started yet)
        for (workers, 0..) |*w, i| {
            w.* = Worker{
                .id = i,
                .queue = queue_ptrs[i],
                .running = undefined, // Set in start()
                .allocator = allocator,
                .handler = undefined, // Set in start()
                .handler_context = null,
                .config = .{
                    .max_connections = @max(per_worker_conns, 100),
                    .buffer_size = config.buffer_size,
                },
            };
        }

        return .{
            .workers = workers,
            .queues = queues,
            .queue_ptrs = queue_ptrs,
            .distributor = FdDistributor.init(queue_ptrs),
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn start(
        self: *AcceptPool,
        handler: *const fn (*Io.Connection) void,
        context: ?*anyopaque,
    ) !void {
        self.running.store(true, .release);
        self.handler = handler;
        self.handler_context = context;

        // Create listen socket
        self.listen_fd = try createListenSocket(self.config.host, self.config.port);

        // Start worker threads
        for (self.workers) |*w| {
            w.running = &self.running;
            w.handler = handler;
            w.handler_context = context;
            try w.start();
        }

        // Start acceptor thread
        self.acceptor_thread = try std.Thread.spawn(.{}, acceptorMain, .{self});

        std.log.info("AcceptPool listening on http://{s}:{d} ({d} workers)", .{
            self.config.host,
            self.config.port,
            self.workers.len,
        });
    }

    fn createListenSocket(host: []const u8, port: u16) !posix.fd_t {
        const addr = try std.net.Address.parseIp4(host, port);
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(fd, &addr.any, @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 4096);

        return fd;
    }

    fn acceptorMain(self: *AcceptPool) void {
        // Simple polling accept loop
        while (self.running.load(.acquire)) {
            const result = posix.accept(self.listen_fd, null, null, posix.SOCK.NONBLOCK);

            if (result) |new_fd| {
                // Distribute to a worker
                if (!self.distributor.distribute(new_fd)) {
                    // All queues full, close connection
                    posix.close(new_fd);
                }
            } else |err| {
                switch (err) {
                    error.WouldBlock => {
                        // No pending connections, sleep briefly
                        std.Thread.sleep(100_000); // 100µs
                    },
                    else => {
                        std.log.warn("Accept error: {}", .{err});
                    },
                }
            }
        }
    }

    pub fn join(self: *AcceptPool) void {
        // Wait for acceptor
        if (self.acceptor_thread) |t| {
            t.join();
            self.acceptor_thread = null;
        }

        // Wait for workers
        for (self.workers) |*w| {
            w.join();
        }
    }

    pub fn stop(self: *AcceptPool) void {
        self.running.store(false, .release);

        // Wake all worker queues
        for (self.queues) |*q| {
            q.wakeAll();
        }
    }

    pub fn shutdown(self: *AcceptPool) void {
        self.stop();
        self.join();
    }

    pub fn deinit(self: *AcceptPool) void {
        if (self.listen_fd != -1) {
            posix.close(self.listen_fd);
        }

        for (self.queues) |*q| {
            q.deinit();
        }

        self.allocator.free(self.workers);
        self.allocator.free(self.queues);
        self.allocator.free(self.queue_ptrs);
    }
};
