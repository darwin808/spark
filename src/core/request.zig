const std = @import("std");
const Method = @import("../http/method.zig").Method;
const Headers = @import("../http/headers.zig").Headers;
const json_mod = @import("../json/json.zig");

/// HTTP Request.
/// All string slices point into the raw buffer (zero-copy).
pub const Request = struct {
    method: Method,
    path: []const u8,
    query_string: ?[]const u8,
    headers: *const Headers,
    body: ?[]const u8,
    params: ParamMap,
    allocator: std.mem.Allocator,

    // Cached query params (parsed lazily)
    _query_params: ?QueryParams = null,

    // Security limits
    max_query_params: usize = 100,

    pub const ParamMap = std.StringHashMapUnmanaged([]const u8);
    pub const QueryParams = std.StringHashMapUnmanaged([]const u8);

    pub fn init(
        method: Method,
        path: []const u8,
        query_string: ?[]const u8,
        headers: *const Headers,
        body: ?[]const u8,
        allocator: std.mem.Allocator,
    ) Request {
        return .{
            .method = method,
            .path = path,
            .query_string = query_string,
            .headers = headers,
            .body = body,
            .params = .{},
            .allocator = allocator,
        };
    }

    pub fn initWithLimits(
        method: Method,
        path: []const u8,
        query_string: ?[]const u8,
        headers: *const Headers,
        body: ?[]const u8,
        allocator: std.mem.Allocator,
        max_query_params: usize,
    ) Request {
        return .{
            .method = method,
            .path = path,
            .query_string = query_string,
            .headers = headers,
            .body = body,
            .params = .{},
            .allocator = allocator,
            .max_query_params = max_query_params,
        };
    }

    /// Get a route parameter by name (e.g., :id).
    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Get a query parameter by name.
    pub fn query(self: *Request, name: []const u8) ?[]const u8 {
        if (self._query_params == null) {
            self.parseQueryParams();
        }
        if (self._query_params) |qp| {
            return qp.get(name);
        }
        return null;
    }

    fn parseQueryParams(self: *Request) void {
        const qs = self.query_string orelse return;

        var params = QueryParams{};
        var iter = std.mem.splitScalar(u8, qs, '&');
        var count: usize = 0;

        while (iter.next()) |pair| {
            // Enforce query parameter limit
            if (count >= self.max_query_params) {
                break;
            }

            if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                const key = pair[0..eq_pos];
                const value = pair[eq_pos + 1 ..];
                params.put(self.allocator, key, value) catch continue;
                count += 1;
            }
        }

        self._query_params = params;
    }

    /// Get header value by name (case-insensitive).
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Parse request body as JSON into type T.
    pub fn parseJson(self: *const Request, comptime T: type) !T {
        const body_data = self.body orelse return error.NoBody;
        return json_mod.parse(T, body_data, self.allocator);
    }

    /// Get raw body bytes.
    pub fn rawBody(self: *const Request) ?[]const u8 {
        return self.body;
    }

    /// Get content type.
    pub fn contentType(self: *const Request) ?[]const u8 {
        return self.header("Content-Type");
    }

    /// Check if request accepts JSON.
    pub fn acceptsJson(self: *const Request) bool {
        const accept = self.header("Accept") orelse return true;
        return std.mem.indexOf(u8, accept, "application/json") != null or
            std.mem.indexOf(u8, accept, "*/*") != null;
    }

    /// Get the full URL path including query string.
    pub fn fullPath(self: *const Request) []const u8 {
        if (self.query_string) |qs| {
            return std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ self.path, qs }) catch self.path;
        }
        return self.path;
    }
};
