const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Router = @import("router.zig").Router;
const RouteGroup = @import("router.zig").RouteGroup;
const Handler = @import("router.zig").Handler;
const MiddlewareType = @import("router.zig").Middleware;
const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const HttpParser = @import("../http/parser.zig").Parser;
const Method = @import("../http/method.zig").Method;
const Io = @import("../io/io.zig").Io;
const middlewareExec = @import("middleware.zig");
const recovery = @import("../middleware/recovery.zig");

// Global reference for signal handlers (only one server per process)
var global_spark: ?*Spark = null;

/// Spark web application.
pub const Spark = struct {
    router: Router,
    config: Config,
    allocator: std.mem.Allocator,
    io: ?Io = null,

    pub const Config = struct {
        port: u16 = 3000,
        host: []const u8 = "127.0.0.1",
        max_connections: usize = 10000,
        buffer_size: usize = 16 * 1024,
        read_timeout_ms: u32 = 10000, // 10s - reduced for slowloris protection
        write_timeout_ms: u32 = 30000,
        // Security limits
        max_body_size: usize = 1024 * 1024, // 1MB
        max_header_size: usize = 8 * 1024, // 8KB per header
        max_headers: usize = 100,
        max_query_params: usize = 100,
        max_uri_length: usize = 8 * 1024, // 8KB
    };

    /// Initialize a new Spark application.
    pub fn init(allocator: std.mem.Allocator) Spark {
        return .{
            .router = Router.init(allocator),
            .config = .{},
            .allocator = allocator,
        };
    }

    /// Initialize with custom configuration.
    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) Spark {
        return .{
            .router = Router.init(allocator),
            .config = config,
            .allocator = allocator,
        };
    }

    // ========== Express-style routing ==========

    /// Register global middleware.
    pub fn use(self: *Spark, mw: MiddlewareType) *Spark {
        self.router.use(mw);
        return self;
    }

    /// Register GET route.
    pub fn get(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.get(path, handler);
        return self;
    }

    /// Register POST route.
    pub fn post(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.post(path, handler);
        return self;
    }

    /// Register PUT route.
    pub fn put(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.put(path, handler);
        return self;
    }

    /// Register DELETE route.
    pub fn delete(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.delete(path, handler);
        return self;
    }

    /// Register PATCH route.
    pub fn patch(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.patch(path, handler);
        return self;
    }

    /// Register HEAD route.
    pub fn head(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.head(path, handler);
        return self;
    }

    /// Register OPTIONS route.
    pub fn options(self: *Spark, path: []const u8, handler: Handler) *Spark {
        self.router.options(path, handler);
        return self;
    }

    /// Register route with any method.
    pub fn route(self: *Spark, method: Method, path: []const u8, handler: Handler) *Spark {
        self.router.route(method, path, handler);
        return self;
    }

    /// Create a route group with prefix.
    pub fn group(self: *Spark, prefix: []const u8) RouteGroup {
        return RouteGroup.init(&self.router, prefix);
    }

    // ========== Server lifecycle ==========

    /// Start the server on configured port.
    pub fn listen(self: *Spark) !void {
        return self.listenOn(self.config.port);
    }

    /// Start the server on specific port.
    pub fn listenOn(self: *Spark, port: u16) !void {
        self.io = try Io.init(self.allocator, .{
            .max_connections = self.config.max_connections,
            .buffer_size = self.config.buffer_size,
        });

        const listen_fd = try self.io.?.listen(self.config.host, port);

        std.log.info("Spark listening on http://{s}:{d}", .{ self.config.host, port });

        try self.io.?.run(listen_fd, handleRequest, self);
    }

    fn handleRequest(conn: *Io.Connection) void {
        // Get Spark instance from connection context
        const self: *Spark = @ptrCast(@alignCast(conn.context orelse return));

        // Parse HTTP request with security limits from config
        var parser = HttpParser.initWithLimits(.{
            .max_uri_length = self.config.max_uri_length,
            .max_header_size = self.config.max_header_size,
            .max_headers = self.config.max_headers,
            .max_body_size = self.config.max_body_size,
        });
        const parse_result = parser.parse(conn.readData()) catch |err| {
            switch (err) {
                error.Incomplete => return, // Need more data, wait for next read
                error.UriTooLong => {
                    const response_414 = "HTTP/1.1 414 URI Too Long\r\nContent-Length: 12\r\n\r\nURI Too Long";
                    @memcpy(conn.write_buffer[0..response_414.len], response_414);
                    conn.write_len = response_414.len;
                    return;
                },
                error.HeaderTooLarge, error.TooManyHeaders => {
                    const response_431 = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 31\r\n\r\nRequest Header Fields Too Large";
                    @memcpy(conn.write_buffer[0..response_431.len], response_431);
                    conn.write_len = response_431.len;
                    return;
                },
                error.BodyTooLarge => {
                    const response_413 = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 16\r\n\r\nPayload Too Large";
                    @memcpy(conn.write_buffer[0..response_413.len], response_413);
                    conn.write_len = response_413.len;
                    return;
                },
                else => {
                    // Send 400 Bad Request for other parse errors
                    const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
                    @memcpy(conn.write_buffer[0..bad_request.len], bad_request);
                    conn.write_len = bad_request.len;
                    return;
                },
            }
        };

        // Create request object with security limits
        var request = Request.initWithLimits(
            parse_result.method,
            parse_result.path,
            parse_result.query,
            parse_result.headers,
            parse_result.body,
            self.allocator,
            self.config.max_query_params,
        );

        // Create response object
        var response = Response.init(self.allocator);
        defer response.deinit();

        // Create context
        var ctx = Context.init(&request, &response, self.allocator);

        // Match route
        if (self.router.match(parse_result.method, parse_result.path, self.allocator)) |match_result| {
            // Copy route params to request
            for (match_result.params) |p| {
                request.params.put(self.allocator, p.name, p.value) catch {};
            }

            // Execute middleware chain then handler
            for (self.router.middleware.items) |mw| {
                mw(&ctx) catch {};
                if (!ctx._next_called) break;
                ctx._next_called = false;
            }

            // Call the route handler
            if (!response.written) {
                match_result.handler(&ctx) catch |err| {
                    // Handler error - send 500
                    ctx.internalError();
                    std.log.err("Handler error: {}", .{err});
                };
            }
        } else {
            // No route matched - 404
            ctx.notFound();
        }

        // Serialize response to write buffer
        const len = response.serialize(conn.write_buffer) catch {
            // Serialization failed - send minimal error
            const server_error = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error";
            @memcpy(conn.write_buffer[0..server_error.len], server_error);
            conn.write_len = server_error.len;
            return;
        };
        conn.write_len = len;
    }

    /// Stop the server.
    pub fn shutdown(self: *Spark) void {
        if (self.io) |*io| {
            io.stop();
        }
    }

    /// Enable signal handlers for graceful shutdown (SIGTERM, SIGINT).
    /// This allows the server to be stopped cleanly by external signals.
    pub fn enableSignalHandlers(self: *Spark) !void {
        global_spark = self;

        const handler = posix.Sigaction{
            .handler = .{ .handler = handleShutdownSignal },
            .mask = posix.empty_sigset,
            .flags = 0,
        };

        try posix.sigaction(posix.SIG.TERM, &handler, null);
        try posix.sigaction(posix.SIG.INT, &handler, null);
    }

    /// Disable signal handlers and clear global reference.
    pub fn disableSignalHandlers(_: *Spark) void {
        const default_handler = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.empty_sigset,
            .flags = 0,
        };

        posix.sigaction(posix.SIG.TERM, &default_handler, null) catch {};
        posix.sigaction(posix.SIG.INT, &default_handler, null) catch {};
        global_spark = null;
    }

    fn handleShutdownSignal(_: c_int) callconv(.C) void {
        if (global_spark) |spark| {
            spark.shutdown();
        }
    }

    pub fn deinit(self: *Spark) void {
        self.router.deinit();
        if (self.io) |*io| {
            io.deinit();
        }
    }
};
