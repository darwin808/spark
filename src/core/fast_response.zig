const std = @import("std");
const Status = @import("../http/status.zig").Status;
const fast_json = @import("../json/fast_serializer.zig");
const date_cache = @import("date_cache.zig");

/// Pre-computed HTTP status lines for common responses (includes trailing \r\n)
const STATUS_LINES = struct {
    const @"200" = "HTTP/1.1 200 OK\r\n";
    const @"201" = "HTTP/1.1 201 Created\r\n";
    const @"204" = "HTTP/1.1 204 No Content\r\n";
    const @"400" = "HTTP/1.1 400 Bad Request\r\n";
    const @"401" = "HTTP/1.1 401 Unauthorized\r\n";
    const @"403" = "HTTP/1.1 403 Forbidden\r\n";
    const @"404" = "HTTP/1.1 404 Not Found\r\n";
    const @"500" = "HTTP/1.1 500 Internal Server Error\r\n";
};

/// Pre-computed common headers
const COMMON_HEADERS = struct {
    const content_type_json = "Content-Type: application/json\r\n";
    const content_type_text = "Content-Type: text/plain; charset=utf-8\r\n";
    const content_type_html = "Content-Type: text/html; charset=utf-8\r\n";
    const connection_keep_alive = "Connection: keep-alive\r\n";
};

/// Ultra-fast HTTP response builder.
/// Writes directly to connection buffer with zero intermediate allocations.
pub const FastResponse = struct {
    buffer: []u8,
    pos: usize = 0,
    body_start: usize = 0,
    headers_done: bool = false,
    written: bool = false,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(buffer: []u8) FastResponse {
        return .{ .buffer = buffer };
    }

    /// Write pre-computed status line
    inline fn writeStatusLine(self: *FastResponse, status: Status) void {
        const line = switch (status) {
            .ok => STATUS_LINES.@"200",
            .created => STATUS_LINES.@"201",
            .no_content => STATUS_LINES.@"204",
            .bad_request => STATUS_LINES.@"400",
            .unauthorized => STATUS_LINES.@"401",
            .forbidden => STATUS_LINES.@"403",
            .not_found => STATUS_LINES.@"404",
            .internal_server_error => STATUS_LINES.@"500",
            else => {
                // Fallback for uncommon status codes
                const written = std.fmt.bufPrint(
                    self.buffer[self.pos..],
                    "HTTP/1.1 {d} {s}\r\n",
                    .{ status.code(), status.phrase() },
                ) catch return;
                self.pos += written.len;
                return;
            },
        };
        self.writeRaw(line);
    }

    inline fn writeRaw(self: *FastResponse, data: []const u8) void {
        if (self.pos + data.len <= self.buffer.len) {
            @memcpy(self.buffer[self.pos..][0..data.len], data);
            self.pos += data.len;
        }
    }

    inline fn writeByte(self: *FastResponse, byte: u8) void {
        if (self.pos < self.buffer.len) {
            self.buffer[self.pos] = byte;
            self.pos += 1;
        }
    }

    /// Write header
    fn writeHeader(self: *FastResponse, name: []const u8, value: []const u8) void {
        self.writeRaw(name);
        self.writeRaw(": ");
        self.writeRaw(value);
        self.writeRaw("\r\n");
    }

    /// Write Content-Length header with integer value
    fn writeContentLength(self: *FastResponse, length: usize) void {
        self.writeRaw("Content-Length: ");
        var buf: [20]u8 = undefined;
        const len_str = std.fmt.bufPrint(&buf, "{d}", .{length}) catch return;
        self.writeRaw(len_str);
        self.writeRaw("\r\n");
    }

    /// Finalize headers (write Date + CRLF)
    fn finalizeHeaders(self: *FastResponse) void {
        // Date header
        const date_str = date_cache.global.get();
        if (date_str.len > 0) {
            self.writeRaw("Date: ");
            self.writeRaw(date_str);
            self.writeRaw("\r\n");
        }
        // End of headers
        self.writeRaw("\r\n");
        self.headers_done = true;
        self.body_start = self.pos;
    }

    /// Send JSON response - writes directly to buffer
    pub fn json(self: *FastResponse, status: Status, value: anytype) void {
        self.writeStatusLine(status);
        self.writeRaw(COMMON_HEADERS.content_type_json);

        // Serialize JSON first to a temp location to know the length
        var temp_buf: [8192]u8 = undefined;
        var serializer = fast_json.FastSerializer.init(&temp_buf);
        serializer.serialize(value) catch {
            self.pos = 0;
            self.writeRaw("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error");
            self.written = true;
            return;
        };
        const body = serializer.slice();

        // Now write Content-Length with exact value
        self.writeContentLength(body.len);
        self.finalizeHeaders();

        // Copy body
        self.writeRaw(body);
        self.written = true;
    }

    /// Send text response
    pub fn text(self: *FastResponse, status: Status, data: []const u8) void {
        self.writeStatusLine(status);
        self.writeRaw(COMMON_HEADERS.content_type_text);
        self.writeContentLength(data.len);
        self.finalizeHeaders();
        self.writeRaw(data);
        self.written = true;
    }

    /// Send raw bytes
    pub fn raw(self: *FastResponse, status: Status, content_type: []const u8, data: []const u8) void {
        self.writeStatusLine(status);
        self.writeHeader("Content-Type", content_type);
        self.writeContentLength(data.len);
        self.finalizeHeaders();
        self.writeRaw(data);
        self.written = true;
    }

    /// Get total bytes written
    pub inline fn len(self: *const FastResponse) usize {
        return self.pos;
    }

    /// Check if response was written
    pub inline fn isWritten(self: *const FastResponse) bool {
        return self.written;
    }
};

// Convenience pre-built responses (static, no allocation)
pub const STATIC_RESPONSES = struct {
    pub const not_found = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found";
    pub const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nBad Request";
    pub const internal_error = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 21\r\n\r\nInternal Server Error";
    pub const method_not_allowed = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: 18\r\n\r\nMethod Not Allowed";
};

test "fast response json" {
    var buffer: [1024]u8 = undefined;
    var resp = FastResponse.init(&buffer);

    const data = .{ .id = 1, .name = "test" };
    resp.json(.ok, data);

    const output = buffer[0..resp.len()];
    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":1") != null);
}

test "fast response text" {
    var buffer: [1024]u8 = undefined;
    var resp = FastResponse.init(&buffer);

    resp.text(.ok, "Hello, World!");

    const output = buffer[0..resp.len()];
    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello, World!") != null);
}
