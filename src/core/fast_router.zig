const std = @import("std");
const Method = @import("../http/method.zig").Method;

/// Handler function type - takes any context pointer
pub const Handler = *const fn (*anyopaque) anyerror!void;
pub const Middleware = Handler;

/// Maximum route parameters per request (stack allocated)
pub const MAX_PARAMS = 8;

/// Pre-allocated parameter pair (zero allocation matching)
pub const ParamPair = struct {
    name: []const u8,
    value: []const u8,
};

/// Fixed-size parameter buffer (stack allocated, zero heap allocation)
pub const ParamBuffer = struct {
    items: [MAX_PARAMS]ParamPair = undefined,
    len: u8 = 0,

    pub inline fn append(self: *ParamBuffer, name: []const u8, value: []const u8) void {
        if (self.len < MAX_PARAMS) {
            self.items[self.len] = .{ .name = name, .value = value };
            self.len += 1;
        }
    }

    pub inline fn slice(self: *const ParamBuffer) []const ParamPair {
        return self.items[0..self.len];
    }

    pub inline fn reset(self: *ParamBuffer) void {
        self.len = 0;
    }
};

/// Radix tree node for fast path matching
const Node = struct {
    /// Path segment (empty for root)
    segment: []const u8 = "",
    /// Handler if this is a leaf node (null for intermediate nodes)
    handler: ?Handler = null,
    /// Children indexed by first character (sparse, most paths start with limited chars)
    children: std.ArrayListUnmanaged(*Node) = .{},
    /// Parameter name if this is a param node (":id" -> "id")
    param_name: ?[]const u8 = null,
    /// Wildcard child (matches rest of path)
    wildcard: ?*Node = null,
    /// Is this a parameter segment?
    is_param: bool = false,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }

    fn findChild(self: *Node, segment: []const u8) ?*Node {
        for (self.children.items) |child| {
            if (!child.is_param and std.mem.eql(u8, child.segment, segment)) {
                return child;
            }
        }
        return null;
    }

    fn findParamChild(self: *Node) ?*Node {
        for (self.children.items) |child| {
            if (child.is_param) return child;
        }
        return null;
    }
};

/// High-performance radix tree router with method-first dispatch
pub const FastRouter = struct {
    /// Separate tree per HTTP method (most common methods)
    trees: [9]?*Node = [_]?*Node{null} ** 9, // GET=0, POST=1, PUT=2, DELETE=3, PATCH=4, HEAD=5, OPTIONS=6, CONNECT=7, TRACE=8
    middleware: std.ArrayListUnmanaged(Middleware) = .{},
    allocator: std.mem.Allocator,

    const MatchResult = struct {
        handler: Handler,
        params: *const ParamBuffer,
    };

    pub fn init(allocator: std.mem.Allocator) FastRouter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FastRouter) void {
        for (&self.trees) |*tree| {
            if (tree.*) |node| {
                node.deinit(self.allocator);
                self.allocator.destroy(node);
                tree.* = null;
            }
        }
        self.middleware.deinit(self.allocator);
    }

    fn methodIndex(method: Method) usize {
        return switch (method) {
            .GET => 0,
            .POST => 1,
            .PUT => 2,
            .DELETE => 3,
            .PATCH => 4,
            .HEAD => 5,
            .OPTIONS => 6,
            .CONNECT => 7,
            .TRACE => 8,
        };
    }

    pub fn use(self: *FastRouter, mw: Middleware) void {
        self.middleware.append(self.allocator, mw) catch {};
    }

    pub fn route(self: *FastRouter, method: Method, pattern: []const u8, handler: Handler) void {
        const idx = methodIndex(method);

        // Create root node if needed
        if (self.trees[idx] == null) {
            self.trees[idx] = self.allocator.create(Node) catch return;
            self.trees[idx].?.* = .{};
        }

        var node = self.trees[idx].?;
        const normalized = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;

        if (normalized.len == 0) {
            node.handler = handler;
            return;
        }

        // Split path and insert segments
        var iter = std.mem.splitScalar(u8, normalized, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;

            if (segment[0] == ':') {
                // Parameter segment
                const param_name = segment[1..];
                if (node.findParamChild()) |child| {
                    node = child;
                } else {
                    const new_node = self.allocator.create(Node) catch return;
                    new_node.* = .{
                        .segment = segment,
                        .is_param = true,
                        .param_name = param_name,
                    };
                    node.children.append(self.allocator, new_node) catch return;
                    node = new_node;
                }
            } else if (std.mem.eql(u8, segment, "*")) {
                // Wildcard
                if (node.wildcard == null) {
                    const new_node = self.allocator.create(Node) catch return;
                    new_node.* = .{ .segment = "*" };
                    node.wildcard = new_node;
                }
                node = node.wildcard.?;
            } else {
                // Literal segment
                if (node.findChild(segment)) |child| {
                    node = child;
                } else {
                    const new_node = self.allocator.create(Node) catch return;
                    new_node.* = .{ .segment = segment };
                    node.children.append(self.allocator, new_node) catch return;
                    node = new_node;
                }
            }
        }

        node.handler = handler;
    }

    // Convenience methods
    pub fn get(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.GET, pattern, handler);
    }

    pub fn post(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.POST, pattern, handler);
    }

    pub fn put(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *FastRouter, pattern: []const u8, handler: Handler) void {
        self.route(.OPTIONS, pattern, handler);
    }

    /// Zero-allocation path matching
    /// Returns handler and fills params buffer (stack allocated by caller)
    pub fn match(self: *FastRouter, method: Method, path: []const u8, params: *ParamBuffer) ?Handler {
        const idx = methodIndex(method);
        const root = self.trees[idx] orelse return null;

        params.reset();
        return self.matchNode(root, path, params);
    }

    fn matchNode(self: *FastRouter, node: *Node, path: []const u8, params: *ParamBuffer) ?Handler {
        _ = self;
        const normalized = if (path.len > 0 and path[0] == '/') path[1..] else path;

        // Handle root path
        if (normalized.len == 0) {
            return node.handler;
        }

        var current = node;
        var remaining = normalized;

        while (remaining.len > 0) {
            // Find end of current segment
            const seg_end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
            const segment = remaining[0..seg_end];
            remaining = if (seg_end < remaining.len) remaining[seg_end + 1 ..] else "";

            // Skip empty segments
            if (segment.len == 0) continue;

            // Try literal match first (fastest path)
            if (current.findChild(segment)) |child| {
                current = child;
                continue;
            }

            // Try parameter match
            if (current.findParamChild()) |param_node| {
                params.append(param_node.param_name.?, segment);
                current = param_node;
                continue;
            }

            // Try wildcard
            if (current.wildcard) |wildcard_node| {
                // Wildcard matches rest of path
                params.append("*", segment);
                return wildcard_node.handler;
            }

            // No match
            return null;
        }

        return current.handler;
    }
};

test "fast router basic matching" {
    const allocator = std.testing.allocator;
    var router = FastRouter.init(allocator);
    defer router.deinit();

    const dummy: Handler = @ptrCast(&struct {
        fn handler(_: *anyopaque) anyerror!void {}
    }.handler);

    router.get("/users", dummy);
    router.get("/users/:id", dummy);
    router.post("/users", dummy);

    var params: ParamBuffer = .{};

    // Test exact match
    {
        const result = router.match(.GET, "/users", &params);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u8, 0), params.len);
    }

    // Test param extraction
    {
        params.reset();
        const result = router.match(.GET, "/users/123", &params);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u8, 1), params.len);
        try std.testing.expectEqualStrings("id", params.items[0].name);
        try std.testing.expectEqualStrings("123", params.items[0].value);
    }

    // Test method mismatch
    {
        params.reset();
        const result = router.match(.DELETE, "/users", &params);
        try std.testing.expect(result == null);
    }
}

test "fast router multiple params" {
    const allocator = std.testing.allocator;
    var router = FastRouter.init(allocator);
    defer router.deinit();

    const dummy: Handler = @ptrCast(&struct {
        fn handler(_: *anyopaque) anyerror!void {}
    }.handler);

    router.get("/users/:userId/posts/:postId", dummy);

    var params: ParamBuffer = .{};
    const result = router.match(.GET, "/users/42/posts/99", &params);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 2), params.len);
    try std.testing.expectEqualStrings("userId", params.items[0].name);
    try std.testing.expectEqualStrings("42", params.items[0].value);
    try std.testing.expectEqualStrings("postId", params.items[1].name);
    try std.testing.expectEqualStrings("99", params.items[1].value);
}
