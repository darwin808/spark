const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const tls = @import("../tls/tls.zig");
const Kqueue = @import("kqueue.zig").Kqueue;
const BufferPool = @import("buffer_pool.zig").BufferPool;

/// TLS-enabled I/O layer for HTTPS support.
/// Uses kqueue for event notification + OpenSSL for encryption.
pub const TlsIo = struct {
    kq: Kqueue,
    tls_server: tls.TlsServer,
    connections: TlsConnectionPool,
    buffer_pool: BufferPool,
    allocator: std.mem.Allocator,
    config: Config,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handler_context: ?*anyopaque = null,

    pub const Config = struct {
        cert_path: []const u8,
        key_path: []const u8,
        max_connections: usize = 10000,
        buffer_size: usize = 16 * 1024,
        max_events: usize = 1024,
    };

    pub const Connection = struct {
        fd: posix.fd_t,
        ssl_conn: ?tls.SslConnection = null,
        state: State,
        read_buffer: []u8,
        read_pos: usize = 0,
        write_buffer: []u8,
        write_pos: usize = 0,
        write_len: usize = 0,
        index: usize,
        context: ?*anyopaque = null,
        handshake_done: bool = false,

        pub const State = enum {
            idle,
            handshaking,
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

        pub fn reset(self: *Connection) void {
            self.read_pos = 0;
            self.write_pos = 0;
            self.write_len = 0;
            self.state = .idle;
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !TlsIo {
        var tls_server = try tls.TlsServer.init(allocator, .{
            .cert_path = config.cert_path,
            .key_path = config.key_path,
        });
        errdefer tls_server.deinit();

        var kq = try Kqueue.init(allocator, config.max_events);
        errdefer kq.deinit();

        var buffer_pool = try BufferPool.init(
            allocator,
            config.max_connections * 2,
            config.buffer_size,
        );
        errdefer buffer_pool.deinit();

        const connections = try TlsConnectionPool.init(allocator, config.max_connections);

        return .{
            .kq = kq,
            .tls_server = tls_server,
            .connections = connections,
            .buffer_pool = buffer_pool,
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn listen(self: *TlsIo, host: []const u8, port: u16) !posix.fd_t {
        _ = self;

        const addr = try std.net.Address.parseIp4(host, port);
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(fd, &addr.any, @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 128);

        return fd;
    }

    pub fn run(
        self: *TlsIo,
        listen_fd: posix.fd_t,
        handler: *const fn (*Connection) void,
        context: ?*anyopaque,
    ) !void {
        self.running.store(true, .release);
        self.handler_context = context;

        try self.kq.register(listen_fd, .read, 0);

        while (self.running.load(.acquire)) {
            const events = try self.kq.wait(100);

            for (events) |ev| {
                if (ev.fd == listen_fd) {
                    self.acceptConnection(listen_fd) catch |err| {
                        std.log.warn("TLS accept error: {}", .{err});
                        continue;
                    };
                } else {
                    const conn = self.connections.get(ev.udata) orelse continue;

                    if (ev.isEof() or ev.isError()) {
                        self.closeConnection(conn);
                        continue;
                    }

                    self.handleConnection(conn, ev.filter, handler);
                }
            }
        }
    }

    fn acceptConnection(self: *TlsIo, listen_fd: posix.fd_t) !void {
        const new_fd = try posix.accept(listen_fd, null, null, posix.SOCK.NONBLOCK);
        errdefer posix.close(new_fd);

        const conn = self.connections.acquire() orelse {
            posix.close(new_fd);
            return error.ConnectionPoolExhausted;
        };
        errdefer self.connections.release(conn);

        conn.fd = new_fd;
        conn.state = .handshaking;
        conn.handshake_done = false;
        conn.context = self.handler_context;

        // Get buffers
        const read_buf = self.buffer_pool.acquire() orelse return error.BufferPoolExhausted;
        errdefer self.buffer_pool.release(read_buf);
        const write_buf = self.buffer_pool.acquire() orelse return error.BufferPoolExhausted;

        conn.read_buffer = read_buf.data;
        conn.write_buffer = write_buf.data;
        conn.reset();

        // Initialize SSL connection (handshake happens later)
        conn.ssl_conn = tls.SslConnection.init(&self.tls_server.ctx, new_fd) catch |err| {
            std.log.warn("TLS connection init failed: {}", .{err});
            return err;
        };

        // Register for read events - handshake will happen in handleConnection
        try self.kq.register(new_fd, .read, conn.index);
    }

    fn handleConnection(
        self: *TlsIo,
        conn: *Connection,
        filter: Kqueue.Filter,
        handler: *const fn (*Connection) void,
    ) void {
        // Handle TLS handshake if not done
        if (!conn.handshake_done) {
            var ssl_conn = &(conn.ssl_conn orelse return);
            ssl_conn.accept() catch |err| {
                switch (err) {
                    tls.SslError.WouldBlock => {
                        // Handshake needs more data, wait for next event
                        return;
                    },
                    else => {
                        std.log.warn("TLS handshake failed: {}", .{err});
                        self.closeConnection(conn);
                        return;
                    },
                }
            };
            conn.handshake_done = true;
            conn.state = .idle;
            return; // Wait for next event to process actual data
        }

        switch (filter) {
            .read => {
                const ssl_conn = &(conn.ssl_conn orelse return);
                const n = ssl_conn.read(conn.readSlice()) catch |err| {
                    switch (err) {
                        tls.SslError.WouldBlock => return,
                        tls.SslError.Shutdown => {
                            self.closeConnection(conn);
                            return;
                        },
                        else => {
                            std.log.warn("TLS read error: {}", .{err});
                            self.closeConnection(conn);
                            return;
                        },
                    }
                };

                if (n == 0) {
                    self.closeConnection(conn);
                    return;
                }

                conn.read_pos += n;
                conn.state = .reading;

                // Call handler
                handler(conn);

                if (conn.write_len > 0) {
                    conn.state = .writing;
                    self.kq.modify(conn.fd, .read, .write, conn.index) catch {
                        self.closeConnection(conn);
                    };
                }
            },
            .write => {
                const ssl_conn = &(conn.ssl_conn orelse return);
                const remaining = conn.write_buffer[conn.write_pos..conn.write_len];
                const n = ssl_conn.write(remaining) catch |err| {
                    switch (err) {
                        tls.SslError.WouldBlock => return,
                        else => {
                            std.log.warn("TLS write error: {}", .{err});
                            self.closeConnection(conn);
                            return;
                        },
                    }
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

    fn closeConnection(self: *TlsIo, conn: *Connection) void {
        if (conn.state == .closed) return;
        conn.state = .closed;

        self.kq.remove(conn.fd, .read) catch {};
        self.kq.remove(conn.fd, .write) catch {};

        if (conn.ssl_conn) |*ssl| {
            ssl.shutdown();
            ssl.deinit();
            conn.ssl_conn = null;
        }

        posix.close(conn.fd);
        self.connections.release(conn);
    }

    pub fn stop(self: *TlsIo) void {
        self.running.store(false, .release);
    }

    pub fn deinit(self: *TlsIo) void {
        self.kq.deinit();
        self.tls_server.deinit();
        self.connections.deinit();
        self.buffer_pool.deinit();
    }
};

const TlsConnectionPool = struct {
    connections: []TlsIo.Connection,
    free_list: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max: usize) !TlsConnectionPool {
        const conns = try allocator.alloc(TlsIo.Connection, max);
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

    pub fn acquire(self: *TlsConnectionPool) ?*TlsIo.Connection {
        const idx = self.free_list.pop() orelse return null;
        return &self.connections[idx];
    }

    pub fn get(self: *TlsConnectionPool, idx: usize) ?*TlsIo.Connection {
        if (idx >= self.connections.len) return null;
        const conn = &self.connections[idx];
        if (conn.state == .closed) return null;
        return conn;
    }

    pub fn release(self: *TlsConnectionPool, conn: *TlsIo.Connection) void {
        self.free_list.append(self.allocator, conn.index) catch {};
    }

    pub fn deinit(self: *TlsConnectionPool) void {
        self.allocator.free(self.connections);
        self.free_list.deinit(self.allocator);
    }
};
