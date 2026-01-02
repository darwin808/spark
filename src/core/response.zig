const std = @import("std");
const Status = @import("../http/status.zig").Status;
const json_mod = @import("../json/json.zig");

/// HTTP Response builder with chainable API.
pub const Response = struct {
    status: Status = .ok,
    headers: HeaderList,
    body: Body = .{ .empty = {} },
    allocator: std.mem.Allocator,
    written: bool = false,

    pub const Body = union(enum) {
        empty: void,
        bytes: []const u8,
        json_data: []const u8,
    };

    pub const HeaderList = std.ArrayListUnmanaged(Header);
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .headers = .{},
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
        for (self.headers.items) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                h.value = value;
                return self;
            }
        }
        self.headers.append(self.allocator, .{ .name = name, .value = value }) catch {};
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

        // Other headers
        for (self.headers.items) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        // End headers
        try writer.writeAll("\r\n");

        // Body
        try writer.writeAll(body_bytes);

        return fbs.pos;
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
    }

    pub fn reset(self: *Response) void {
        self.status = .ok;
        self.headers.clearRetainingCapacity();
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
