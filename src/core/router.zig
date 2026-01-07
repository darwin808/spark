const std = @import("std");
const Context = @import("context.zig").Context;
const Method = @import("../http/method.zig").Method;

pub const Handler = *const fn (*Context) anyerror!void;
pub const Middleware = Handler;

/// Express-style router with radix tree matching.
pub const Router = struct {
    routes: std.ArrayListUnmanaged(Route),
    middleware: std.ArrayListUnmanaged(Middleware),
    allocator: std.mem.Allocator,

    pub const Route = struct {
        method: Method,
        pattern: []const u8,
        segments: []const Segment,
        handler: Handler,
    };

    pub const Segment = union(enum) {
        literal: []const u8,
        param: []const u8,
        wildcard: void,
    };

    pub const MatchResult = struct {
        handler: Handler,
        params: []const ParamPair,
    };

    pub const ParamPair = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .routes = .{},
            .middleware = .{},
            .allocator = allocator,
        };
    }

    /// Register global middleware.
    pub fn use(self: *Router, mw: Middleware) void {
        self.middleware.append(self.allocator, mw) catch {};
    }

    /// Register a route.
    pub fn route(self: *Router, method: Method, pattern: []const u8, handler: Handler) void {
        const segments = self.compilePattern(pattern) catch return;
        self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .segments = segments,
            .handler = handler,
        }) catch {};
    }

    // Convenience methods
    pub fn get(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.GET, pattern, handler);
    }

    pub fn post(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.POST, pattern, handler);
    }

    pub fn put(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *Router, pattern: []const u8, handler: Handler) void {
        self.route(.OPTIONS, pattern, handler);
    }

    /// Match a path and return handler with extracted parameters.
    pub fn match(self: *Router, method: Method, path: []const u8, arena: std.mem.Allocator) ?MatchResult {
        for (self.routes.items) |r| {
            if (r.method != method) continue;

            if (self.matchRoute(&r, path, arena)) |params| {
                return .{
                    .handler = r.handler,
                    .params = params,
                };
            }
        }
        return null;
    }

    fn matchRoute(self: *Router, r: *const Route, path: []const u8, arena: std.mem.Allocator) ?[]const ParamPair {
        _ = self;

        var params = std.ArrayListUnmanaged(ParamPair){};
        const normalized_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
        var path_iter = std.mem.splitScalar(u8, normalized_path, '/');
        var seg_idx: usize = 0;

        while (seg_idx < r.segments.len) {
            const segment = r.segments[seg_idx];

            switch (segment) {
                .literal => |lit| {
                    const path_part = path_iter.next() orelse return null;
                    if (!std.mem.eql(u8, path_part, lit)) return null;
                },
                .param => |name| {
                    const path_part = path_iter.next() orelse return null;
                    params.append(arena, .{ .name = name, .value = path_part }) catch return null;
                },
                .wildcard => {
                    // Match rest of path
                    var rest = std.ArrayListUnmanaged(u8){};
                    while (path_iter.next()) |part| {
                        if (rest.items.len > 0) rest.append(arena, '/') catch {};
                        rest.appendSlice(arena, part) catch {};
                    }
                    params.append(arena, .{ .name = "*", .value = rest.items }) catch return null;
                    return params.items;
                },
            }

            seg_idx += 1;
        }

        // Check if we consumed all path segments (skip empty parts)
        while (path_iter.next()) |remaining| {
            if (remaining.len > 0) return null; // Non-empty segment remaining = no match
        }

        return params.items;
    }

    fn compilePattern(self: *Router, pattern: []const u8) ![]const Segment {
        var segments = std.ArrayListUnmanaged(Segment){};

        const normalized = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
        if (normalized.len == 0) return segments.items;

        var iter = std.mem.splitScalar(u8, normalized, '/');

        while (iter.next()) |part| {
            if (part.len == 0) continue;

            if (part[0] == ':') {
                try segments.append(self.allocator, .{ .param = part[1..] });
            } else if (std.mem.eql(u8, part, "*")) {
                try segments.append(self.allocator, .{ .wildcard = {} });
            } else {
                try segments.append(self.allocator, .{ .literal = part });
            }
        }

        return segments.items;
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
        self.middleware.deinit(self.allocator);
    }
};

/// Route group for organizing related routes with a common prefix.
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    group_middleware: std.ArrayListUnmanaged(Middleware),

    pub fn init(router: *Router, prefix: []const u8) RouteGroup {
        return .{
            .router = router,
            .prefix = prefix,
            .group_middleware = .{},
        };
    }

    pub fn use(self: *RouteGroup, mw: Middleware) *RouteGroup {
        self.group_middleware.append(self.router.allocator, mw) catch {};
        return self;
    }

    fn fullPath(self: *RouteGroup, path: []const u8) []const u8 {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return self.prefix;
        }
        return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path }) catch self.prefix;
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: Handler) *RouteGroup {
        self.router.get(self.fullPath(path), handler);
        return self;
    }

    pub fn post(self: *RouteGroup, path: []const u8, handler: Handler) *RouteGroup {
        self.router.post(self.fullPath(path), handler);
        return self;
    }

    pub fn put(self: *RouteGroup, path: []const u8, handler: Handler) *RouteGroup {
        self.router.put(self.fullPath(path), handler);
        return self;
    }

    pub fn delete(self: *RouteGroup, path: []const u8, handler: Handler) *RouteGroup {
        self.router.delete(self.fullPath(path), handler);
        return self;
    }

    pub fn patch(self: *RouteGroup, path: []const u8, handler: Handler) *RouteGroup {
        self.router.patch(self.fullPath(path), handler);
        return self;
    }
};

test "router basic matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const dummy = struct {
        fn handler(_: *Context) anyerror!void {}
    }.handler;

    router.get("/users", dummy);
    router.get("/users/:id", dummy);
    router.post("/users", dummy);

    // Test exact match
    {
        const result = router.match(.GET, "/users", allocator).?;
        try std.testing.expectEqual(@as(usize, 0), result.params.len);
    }

    // Test param extraction
    {
        const result = router.match(.GET, "/users/123", allocator).?;
        try std.testing.expectEqual(@as(usize, 1), result.params.len);
        try std.testing.expectEqualStrings("id", result.params[0].name);
        try std.testing.expectEqualStrings("123", result.params[0].value);
    }

    // Test method mismatch
    {
        const result = router.match(.DELETE, "/users", allocator);
        try std.testing.expectEqual(@as(?Router.MatchResult, null), result);
    }
}

test "router with multiple params" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const dummy = struct {
        fn handler(_: *Context) anyerror!void {}
    }.handler;

    router.get("/users/:userId/posts/:postId", dummy);

    const result = router.match(.GET, "/users/42/posts/99", allocator).?;
    try std.testing.expectEqual(@as(usize, 2), result.params.len);
    try std.testing.expectEqualStrings("userId", result.params[0].name);
    try std.testing.expectEqualStrings("42", result.params[0].value);
    try std.testing.expectEqualStrings("postId", result.params[1].name);
    try std.testing.expectEqualStrings("99", result.params[1].value);
}
