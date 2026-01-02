const std = @import("std");
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
        read_timeout_ms: u32 = 30000,
        write_timeout_ms: u32 = 30000,
        max_body_size: usize = 1024 * 1024,
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

        try self.io.?.run(listen_fd, self.handleConnection());
    }

    fn handleConnection(self: *Spark) *const fn (*Io.Connection) void {
        _ = self;
        return struct {
            fn handler(conn: *Io.Connection) void {
                _ = conn;
                // Placeholder - actual request handling
            }
        }.handler;
    }

    /// Stop the server.
    pub fn shutdown(self: *Spark) void {
        if (self.io) |*io| {
            io.stop();
        }
    }

    pub fn deinit(self: *Spark) void {
        self.router.deinit();
        if (self.io) |*io| {
            io.deinit();
        }
    }
};
