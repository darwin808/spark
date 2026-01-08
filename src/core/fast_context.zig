const std = @import("std");
const Request = @import("request.zig").Request;
const FastResponse = @import("fast_response.zig").FastResponse;
const STATIC_RESPONSES = @import("fast_response.zig").STATIC_RESPONSES;
const Status = @import("../http/status.zig").Status;
const fast_router = @import("fast_router.zig");
const json_parser = @import("../json/parser.zig");

/// Ultra-fast request context with zero-allocation response path.
pub const FastContext = struct {
    request: *Request,
    response: *FastResponse,
    params: *const fast_router.ParamBuffer,
    _next_called: bool = false,

    pub fn init(
        request: *Request,
        response: *FastResponse,
        params: *const fast_router.ParamBuffer,
    ) FastContext {
        return .{
            .request = request,
            .response = response,
            .params = params,
        };
    }

    // ========== Request accessors ==========

    /// Get path parameter by name
    pub fn param(self: *FastContext, name: []const u8) ?[]const u8 {
        for (self.params.slice()) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                return p.value;
            }
        }
        return null;
    }

    /// Get query parameter
    pub fn query(self: *FastContext, name: []const u8) ?[]const u8 {
        return self.request.query(name);
    }

    /// Get request header
    pub fn header(self: *FastContext, name: []const u8) ?[]const u8 {
        return self.request.header(name);
    }

    /// Parse request body as JSON
    pub fn body(self: *FastContext, comptime T: type) !T {
        return self.request.parseJson(T);
    }

    /// Get raw request body
    pub fn rawBody(self: *FastContext) []const u8 {
        return self.request.body;
    }

    // ========== Response methods (zero allocation) ==========

    /// Send JSON response with 200 OK
    pub fn ok(self: *FastContext, value: anytype) void {
        self.response.json(.ok, value);
    }

    /// Send JSON response with 201 Created
    pub fn created(self: *FastContext, value: anytype) void {
        self.response.json(.created, value);
    }

    /// Send plain text response
    pub fn text(self: *FastContext, data: []const u8) void {
        self.response.text(.ok, data);
    }

    /// Send 404 Not Found (static response, fastest path)
    pub fn notFound(self: *FastContext) void {
        @memcpy(
            self.response.buffer[0..STATIC_RESPONSES.not_found.len],
            STATIC_RESPONSES.not_found,
        );
        self.response.pos = STATIC_RESPONSES.not_found.len;
        self.response.written = true;
    }

    /// Send 400 Bad Request
    pub fn badRequest(self: *FastContext, _: []const u8) void {
        @memcpy(
            self.response.buffer[0..STATIC_RESPONSES.bad_request.len],
            STATIC_RESPONSES.bad_request,
        );
        self.response.pos = STATIC_RESPONSES.bad_request.len;
        self.response.written = true;
    }

    /// Send 500 Internal Server Error
    pub fn internalError(self: *FastContext) void {
        @memcpy(
            self.response.buffer[0..STATIC_RESPONSES.internal_error.len],
            STATIC_RESPONSES.internal_error,
        );
        self.response.pos = STATIC_RESPONSES.internal_error.len;
        self.response.written = true;
    }

    /// Send JSON with custom status
    pub fn json(self: *FastContext, status: Status, value: anytype) void {
        self.response.json(status, value);
    }

    /// Send raw response with custom content type
    pub fn raw(self: *FastContext, status: Status, content_type: []const u8, data: []const u8) void {
        self.response.raw(status, content_type, data);
    }

    // ========== Middleware support ==========

    pub fn next(self: *FastContext) void {
        self._next_called = true;
    }
};
