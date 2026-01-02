const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Status = @import("../http/status.zig").Status;

/// Context is the primary interface handlers work with.
/// Designed to be noob-friendly - most operations are one-liners.
pub const Context = struct {
    request: *Request,
    response: *Response,
    arena: std.mem.Allocator,
    locals: LocalsMap,
    _next_called: bool = false,

    pub const LocalsMap = std.StringHashMapUnmanaged(*anyopaque);

    pub fn init(request: *Request, response: *Response, arena: std.mem.Allocator) Context {
        return .{
            .request = request,
            .response = response,
            .arena = arena,
            .locals = .{},
        };
    }

    // ========== Request shortcuts ==========

    /// Get route parameter.
    pub fn param(self: *Context, name: []const u8) ?[]const u8 {
        return self.request.param(name);
    }

    /// Get route parameter, returning error if missing.
    pub fn paramRequired(self: *Context, name: []const u8) ![]const u8 {
        return self.request.param(name) orelse error.MissingParam;
    }

    /// Get query parameter.
    pub fn query(self: *Context, name: []const u8) ?[]const u8 {
        return self.request.query(name);
    }

    /// Parse request body as JSON.
    pub fn body(self: *Context, comptime T: type) !T {
        return self.request.parseJson(T);
    }

    /// Get header value.
    pub fn header(self: *Context, name: []const u8) ?[]const u8 {
        return self.request.header(name);
    }

    /// Get raw body bytes.
    pub fn rawBody(self: *Context) ?[]const u8 {
        return self.request.rawBody();
    }

    // ========== Response shortcuts ==========

    /// Send JSON response.
    pub fn json(self: *Context, value: anytype) void {
        _ = self.response.sendJson(value);
    }

    /// Send JSON with specific status.
    pub fn jsonStatus(self: *Context, s: Status, value: anytype) void {
        _ = self.response.setStatus(s).sendJson(value);
    }

    /// Send 200 OK with JSON.
    pub fn ok(self: *Context, value: anytype) void {
        self.json(value);
    }

    /// Send 201 Created with JSON.
    pub fn created(self: *Context, value: anytype) void {
        self.jsonStatus(.created, value);
    }

    /// Send 204 No Content.
    pub fn noContent(self: *Context) void {
        _ = self.response.setStatus(.no_content);
        self.response.written = true;
    }

    /// Send error response.
    pub fn err(self: *Context, s: Status, message: []const u8) void {
        self.jsonStatus(s, .{
            .@"error" = .{
                .message = message,
                .status = s.code(),
            },
        });
    }

    /// Send 400 Bad Request.
    pub fn badRequest(self: *Context, message: []const u8) void {
        self.err(.bad_request, message);
    }

    /// Send 401 Unauthorized.
    pub fn unauthorized(self: *Context, message: []const u8) void {
        self.err(.unauthorized, message);
    }

    /// Send 403 Forbidden.
    pub fn forbidden(self: *Context, message: []const u8) void {
        self.err(.forbidden, message);
    }

    /// Send 404 Not Found.
    pub fn notFound(self: *Context) void {
        self.err(.not_found, "Resource not found");
    }

    /// Send 500 Internal Server Error.
    pub fn internalError(self: *Context) void {
        self.err(.internal_server_error, "Internal server error");
    }

    /// Send raw text.
    pub fn text(self: *Context, data: []const u8) void {
        _ = self.response.sendText(data);
    }

    /// Send HTML.
    pub fn html(self: *Context, data: []const u8) void {
        _ = self.response.sendHtml(data);
    }

    /// Set response status.
    pub fn setStatus(self: *Context, s: Status) *Context {
        _ = self.response.setStatus(s);
        return self;
    }

    /// Set response header.
    pub fn setHeader(self: *Context, name: []const u8, value: []const u8) *Context {
        _ = self.response.setHeader(name, value);
        return self;
    }

    // ========== Middleware control ==========

    /// Call next middleware in chain.
    pub fn next(self: *Context) void {
        self._next_called = true;
    }

    // ========== Local storage ==========

    /// Set a value in locals (for middleware communication).
    pub fn set(self: *Context, comptime T: type, key: []const u8, value: T) void {
        const ptr = self.arena.create(T) catch return;
        ptr.* = value;
        self.locals.put(self.arena, key, ptr) catch {};
    }

    /// Get a value from locals.
    pub fn get(self: *Context, comptime T: type, key: []const u8) ?T {
        const ptr = self.locals.get(key) orelse return null;
        return @as(*T, @ptrCast(@alignCast(ptr))).*;
    }
};
