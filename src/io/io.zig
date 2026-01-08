const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const BufferPool = @import("buffer_pool.zig").BufferPool;

// Platform-specific backends
const Kqueue = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) @import("kqueue.zig").Kqueue else void;
const IoUring = if (builtin.os.tag == .linux) @import("io_uring.zig").IoUring else void;

/// Unified async I/O interface.
/// Uses io_uring on Linux, kqueue on macOS/BSD.
pub const Io = struct {
    backend: Backend,
    allocator: std.mem.Allocator,
    connections: ConnectionPool,
    buffer_pool: BufferPool,
    config: Config,
    running_owned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: ?*std.atomic.Value(bool) = null, // null = use running_owned
    handler_context: ?*anyopaque = null,

    const Backend = union(enum) {
        kqueue: Kqueue,
        io_uring: IoUring,
    };

    pub const Config = struct {
        max_connections: usize = 10000,
        buffer_size: usize = 16 * 1024, // 16KB
        max_events: usize = 1024,
        read_timeout_ms: u32 = 30000,
        write_timeout_ms: u32 = 30000,
    };

    pub const Connection = struct {
        fd: posix.fd_t,
        state: State,
        read_buffer: []u8,
        read_pos: usize = 0,
        write_buffer: []u8,
        write_pos: usize = 0,
        write_len: usize = 0,
        index: usize,
        context: ?*anyopaque = null, // User-defined context (e.g., Spark app)

        pub const State = enum {
            idle,
            reading,
            writing,
            closing,
            closed,
        };

        pub fn readSlice(self: *Connection) []u8 {
            return self.read_buffer[self.read_pos..];
        }

        pub fn readData(self: *Connection) []const u8 {
            return self.read_buffer[0..self.read_pos];
        }

        pub fn writeSlice(self: *Connection) []u8 {
            return self.write_buffer[0..self.write_len];
        }

        pub fn reset(self: *Connection) void {
            self.read_pos = 0;
            self.write_pos = 0;
            self.write_len = 0;
            self.state = .idle;
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Io {
        const backend: Backend = switch (builtin.os.tag) {
            .linux => .{ .io_uring = try IoUring.init(allocator, 4096) },
            .macos, .freebsd => .{ .kqueue = try Kqueue.init(allocator, config.max_events) },
            else => @compileError("Unsupported platform. Spark requires Linux or macOS."),
        };

        const buffer_pool = try BufferPool.init(
            allocator,
            config.max_connections * 2, // Read + write buffers
            config.buffer_size,
        );

        return .{
            .backend = backend,
            .allocator = allocator,
            .connections = try ConnectionPool.init(allocator, config.max_connections),
            .buffer_pool = buffer_pool,
            .config = config,
            // running = null means use running_owned (single-threaded mode)
        };
    }

    /// Initialize with a shared running flag (for multi-threaded mode).
    pub fn initShared(
        allocator: std.mem.Allocator,
        config: Config,
        running: *std.atomic.Value(bool),
    ) !Io {
        const backend: Backend = switch (builtin.os.tag) {
            .linux => .{ .io_uring = try IoUring.init(allocator, 4096) },
            .macos, .freebsd => .{ .kqueue = try Kqueue.init(allocator, config.max_events) },
            else => @compileError("Unsupported platform. Spark requires Linux or macOS."),
        };

        const buffer_pool = try BufferPool.init(
            allocator,
            config.max_connections * 2,
            config.buffer_size,
        );

        return .{
            .backend = backend,
            .allocator = allocator,
            .connections = try ConnectionPool.init(allocator, config.max_connections),
            .buffer_pool = buffer_pool,
            .config = config,
            .running = running, // Use shared flag
        };
    }

    /// Create a listening socket.
    pub fn listen(self: *Io, host: []const u8, port: u16) !posix.fd_t {
        _ = self;

        const addr = try std.net.Address.parseIp4(host, port);
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        // Set socket options
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        if (@hasDecl(posix.SO, "REUSEPORT")) {
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
        }

        try posix.bind(fd, &addr.any, @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 128);

        return fd;
    }

    /// Get the running flag (owned or shared).
    fn getRunning(self: *Io) *std.atomic.Value(bool) {
        return self.running orelse &self.running_owned;
    }

    /// Run the event loop.
    pub fn run(
        self: *Io,
        listen_fd: posix.fd_t,
        handler: *const fn (*Connection) void,
        context: ?*anyopaque,
    ) !void {
        self.getRunning().store(true, .release);
        self.handler_context = context;

        switch (builtin.os.tag) {
            .linux => try self.runIoUring(&self.backend.io_uring, listen_fd, handler),
            .macos, .freebsd => try self.runKqueue(&self.backend.kqueue, listen_fd, handler),
            else => @compileError("Unsupported platform"),
        }
    }

    fn runKqueue(
        self: *Io,
        kq: *Kqueue,
        listen_fd: posix.fd_t,
        handler: *const fn (*Connection) void,
    ) !void {
        // Register listen socket
        try kq.register(listen_fd, .read, 0);

        while (self.getRunning().load(.acquire)) {
            const events = try kq.wait(100);

            for (events) |ev| {
                if (ev.fd == listen_fd) {
                    // Accept new connection
                    self.acceptConnection(kq, listen_fd) catch |err| {
                        std.log.warn("Accept error: {}", .{err});
                        continue;
                    };
                } else {
                    // Handle existing connection
                    const conn = self.connections.get(ev.udata) orelse continue;

                    if (ev.isEof() or ev.isError()) {
                        self.closeConnection(kq, conn);
                        continue;
                    }

                    switch (ev.filter) {
                        .read => {
                            const n = posix.read(conn.fd, conn.readSlice()) catch |err| {
                                std.log.warn("Read error: {}", .{err});
                                self.closeConnection(kq, conn);
                                continue;
                            };

                            if (n == 0) {
                                self.closeConnection(kq, conn);
                                continue;
                            }

                            conn.read_pos += n;
                            conn.state = .reading;

                            // Call handler
                            handler(conn);

                            // If handler wrote a response, switch to write mode
                            if (conn.write_len > 0) {
                                conn.state = .writing;
                                kq.modify(conn.fd, .read, .write, conn.index) catch {
                                    self.closeConnection(kq, conn);
                                    continue;
                                };
                            }
                        },

                        .write => {
                            const remaining = conn.write_buffer[conn.write_pos..conn.write_len];
                            const n = posix.write(conn.fd, remaining) catch |err| {
                                std.log.warn("Write error: {}", .{err});
                                self.closeConnection(kq, conn);
                                continue;
                            };

                            conn.write_pos += n;

                            if (conn.write_pos >= conn.write_len) {
                                // Write complete, reset for next request
                                conn.reset();
                                kq.modify(conn.fd, .write, .read, conn.index) catch {
                                    self.closeConnection(kq, conn);
                                    continue;
                                };
                            }
                        },
                    }
                }
            }
        }
    }

    fn runIoUring(
        self: *Io,
        ring: *IoUring,
        listen_fd: posix.fd_t,
        handler: *const fn (*Connection) void,
    ) !void {
        // Queue initial accept
        try ring.queueAccept(listen_fd, 0);
        _ = try ring.submit();

        while (self.getRunning().load(.acquire)) {
            const completions = try ring.submitAndWait(1);

            for (completions) |cqe| {
                const user_data = cqe.user_data;

                if (user_data == 0) {
                    // Accept completion
                    if (!cqe.isError()) {
                        const new_fd: posix.fd_t = @intCast(cqe.result);
                        if (self.connections.acquire()) |conn| {
                            conn.fd = new_fd;
                            conn.state = .reading;
                            conn.context = self.handler_context;

                            // Get buffer from pool
                            if (self.buffer_pool.acquire()) |buf| {
                                conn.read_buffer = buf.data;
                                if (self.buffer_pool.acquire()) |wbuf| {
                                    conn.write_buffer = wbuf.data;
                                    try ring.queueRead(new_fd, conn.read_buffer, conn.index + 1);
                                } else {
                                    self.buffer_pool.release(buf);
                                    self.connections.release(conn);
                                    posix.close(new_fd);
                                }
                            } else {
                                self.connections.release(conn);
                                posix.close(new_fd);
                            }
                        } else {
                            posix.close(new_fd);
                        }
                    }
                    // Re-queue accept
                    try ring.queueAccept(listen_fd, 0);
                } else {
                    // Connection operation
                    const conn_idx = user_data - 1;
                    const conn = self.connections.get(conn_idx) orelse continue;

                    if (cqe.isError()) {
                        posix.close(conn.fd);
                        conn.state = .closed;
                        self.connections.release(conn);
                        continue;
                    }

                    switch (conn.state) {
                        .reading => {
                            const n: usize = @intCast(cqe.result);
                            if (n == 0) {
                                posix.close(conn.fd);
                                conn.state = .closed;
                                self.connections.release(conn);
                                continue;
                            }

                            conn.read_pos += n;
                            handler(conn);

                            if (conn.write_len > 0) {
                                conn.state = .writing;
                                try ring.queueWrite(conn.fd, conn.writeSlice(), conn.index + 1);
                            } else {
                                try ring.queueRead(conn.fd, conn.readSlice(), conn.index + 1);
                            }
                        },

                        .writing => {
                            const n: usize = @intCast(cqe.result);
                            conn.write_pos += n;

                            if (conn.write_pos >= conn.write_len) {
                                conn.reset();
                                try ring.queueRead(conn.fd, conn.read_buffer, conn.index + 1);
                            } else {
                                try ring.queueWrite(
                                    conn.fd,
                                    conn.write_buffer[conn.write_pos..conn.write_len],
                                    conn.index + 1,
                                );
                            }
                        },

                        else => {},
                    }
                }
            }
        }
    }

    fn acceptConnection(self: *Io, kq: *Kqueue, listen_fd: posix.fd_t) !void {
        const new_fd = try posix.accept(listen_fd, null, null, posix.SOCK.NONBLOCK);
        errdefer posix.close(new_fd);

        const conn = self.connections.acquire() orelse {
            posix.close(new_fd);
            return error.ConnectionPoolExhausted;
        };
        errdefer self.connections.release(conn);

        conn.fd = new_fd;
        conn.state = .idle;
        conn.context = self.handler_context;

        // Get buffers from pool
        const read_buf = self.buffer_pool.acquire() orelse return error.BufferPoolExhausted;
        errdefer self.buffer_pool.release(read_buf);

        const write_buf = self.buffer_pool.acquire() orelse return error.BufferPoolExhausted;

        conn.read_buffer = read_buf.data;
        conn.write_buffer = write_buf.data;
        conn.reset();

        try kq.register(new_fd, .read, conn.index);
    }

    fn closeConnection(self: *Io, kq: *Kqueue, conn: *Connection) void {
        if (conn.state == .closed) return; // Already closed
        conn.state = .closed; // Mark closed first to prevent double-close
        kq.remove(conn.fd, .read) catch {};
        kq.remove(conn.fd, .write) catch {};
        posix.close(conn.fd);
        self.connections.release(conn);
    }

    pub fn stop(self: *Io) void {
        self.getRunning().store(false, .release);
    }

    pub fn deinit(self: *Io) void {
        switch (builtin.os.tag) {
            .linux => self.backend.io_uring.deinit(),
            .macos, .freebsd => self.backend.kqueue.deinit(),
            else => {},
        }
        self.connections.deinit();
        self.buffer_pool.deinit();
    }
};

const ConnectionPool = struct {
    connections: []Io.Connection,
    free_list: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max: usize) !ConnectionPool {
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
            .allocator = allocator,
        };
    }

    pub fn acquire(self: *ConnectionPool) ?*Io.Connection {
        const idx = self.free_list.pop() orelse return null;
        return &self.connections[idx];
    }

    pub fn get(self: *ConnectionPool, idx: usize) ?*Io.Connection {
        if (idx >= self.connections.len) return null;
        const conn = &self.connections[idx];
        if (conn.state == .closed) return null;
        return conn;
    }

    pub fn release(self: *ConnectionPool, conn: *Io.Connection) void {
        self.free_list.append(self.allocator, conn.index) catch {};
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.allocator.free(self.connections);
        self.free_list.deinit(self.allocator);
    }
};
