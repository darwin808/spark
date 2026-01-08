const std = @import("std");
const Status = @import("../http/status.zig").Status;
const json_mod = @import("../json/json.zig");
const date_cache = @import("date_cache.zig");

/// HTTP Response builder with chainable API.
/// Uses fixed-size header array to avoid allocations.
pub const Response = struct {
    status: Status = .ok,
    headers: [max_headers]Header = undefined,
    headers_len: u8 = 0,
    body: Body = .{ .empty = {} },
    allocator: std.mem.Allocator,
    written: bool = false,

    pub const max_headers: u8 = 16;

    pub const Body = union(enum) {
        empty: void,
        bytes: []const u8,
        json_data: []const u8,
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .allocator = allocator,
        };
    }

    /// Set status code - chainable.
    pub fn setStatus(self: *Response, s: Status) *Response {
        self.status = s;
        return self;
    }

    /// Set a header - chainable.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) *Response {
        // Check if header already exists
        for (self.headers[0..self.headers_len]) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                h.value = value;
                return self;
            }
        }
        // Add new header if space available
        if (self.headers_len < max_headers) {
            self.headers[self.headers_len] = .{ .name = name, .value = value };
            self.headers_len += 1;
        }
        return self;
    }

    /// Send JSON response.
    pub fn sendJson(self: *Response, value: anytype) *Response {
        _ = self.setHeader("Content-Type", "application/json");
        const data = json_mod.stringify(self.allocator, value) catch return self;
        self.body = .{ .json_data = data };
        self.written = true;
        return self;
    }

    /// Send raw bytes.
    pub fn send(self: *Response, data: []const u8) *Response {
        self.body = .{ .bytes = data };
        self.written = true;
        return self;
    }

    /// Send text with content-type text/plain.
    pub fn sendText(self: *Response, data: []const u8) *Response {
        _ = self.setHeader("Content-Type", "text/plain; charset=utf-8");
        return self.send(data);
    }

    /// Send HTML.
    pub fn sendHtml(self: *Response, data: []const u8) *Response {
        _ = self.setHeader("Content-Type", "text/html; charset=utf-8");
        return self.send(data);
    }

    /// Serialize response to HTTP wire format.
    pub fn serialize(self: *Response, buffer: []u8) !usize {
        var fbs = std.io.fixedBufferStream(buffer);
        const writer = fbs.writer();

        // Status line
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.phrase() });

        // Get body bytes
        const body_bytes: []const u8 = switch (self.body) {
            .empty => "",
            .bytes => |b| b,
            .json_data => |d| d,
        };

        // Content-Length header
        try writer.print("Content-Length: {d}\r\n", .{body_bytes.len});

        // Date header (pre-computed, updated once per second)
        const date_str = date_cache.global.get();
        if (date_str.len > 0) {
            try writer.print("Date: {s}\r\n", .{date_str});
        }

        // Other headers
        for (self.headers[0..self.headers_len]) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        // End headers
        try writer.writeAll("\r\n");

        // Body
        try writer.writeAll(body_bytes);

        return fbs.pos;
    }

    /// No-op - fixed array doesn't need cleanup.
    /// Kept for API compatibility during transition.
    pub fn deinit(self: *Response) void {
        _ = self;
    }

    pub fn reset(self: *Response) void {
        self.status = .ok;
        self.headers_len = 0;
        self.body = .{ .empty = {} };
        self.written = false;
    }
};

test "response serialization" {
    const allocator = std.testing.allocator;
    var resp = Response.init(allocator);
    defer resp.deinit();

    _ = resp.setStatus(.ok).setHeader("X-Custom", "value").sendText("Hello");

    var buffer: [1024]u8 = undefined;
    const len = try resp.serialize(&buffer);
    const output = buffer[0..len];

    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
}

test "response header replacement" {
    const allocator = std.testing.allocator;
    var resp = Response.init(allocator);

    _ = resp.setHeader("Content-Type", "text/plain");
    _ = resp.setHeader("Content-Type", "application/json");

    // Should have only one Content-Type header with the updated value
    try std.testing.expectEqual(@as(u8, 1), resp.headers_len);
    try std.testing.expectEqualStrings("application/json", resp.headers[0].value);
}

test "response max headers" {
    const allocator = std.testing.allocator;
    var resp = Response.init(allocator);

    // Use distinct string literals for each header
    const header_names = [_][]const u8{
        "X-Header-0",  "X-Header-1",  "X-Header-2",  "X-Header-3",
        "X-Header-4",  "X-Header-5",  "X-Header-6",  "X-Header-7",
        "X-Header-8",  "X-Header-9",  "X-Header-10", "X-Header-11",
        "X-Header-12", "X-Header-13", "X-Header-14", "X-Header-15",
    };

    for (header_names) |name| {
        _ = resp.setHeader(name, "value");
    }

    try std.testing.expectEqual(Response.max_headers, resp.headers_len);

    // Adding one more should be silently ignored
    _ = resp.setHeader("X-Extra", "value");
    try std.testing.expectEqual(Response.max_headers, resp.headers_len);
}

test "response reset" {
    const allocator = std.testing.allocator;
    var resp = Response.init(allocator);

    _ = resp.setStatus(.not_found).setHeader("X-Test", "value").sendText("Not found");

    resp.reset();

    try std.testing.expectEqual(Status.ok, resp.status);
    try std.testing.expectEqual(@as(u8, 0), resp.headers_len);
    try std.testing.expectEqual(Response.Body{ .empty = {} }, resp.body);
    try std.testing.expect(!resp.written);
}
