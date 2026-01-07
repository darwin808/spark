const std = @import("std");
const Method = @import("method.zig").Method;
const Headers = @import("headers.zig").Headers;

/// Zero-copy HTTP/1.1 request parser with security limits.
/// All returned slices point directly into the input buffer.
pub const Parser = struct {
    state: State = .method,
    pos: usize = 0,
    mark: usize = 0,

    // Parsed components (slices into buffer)
    method: ?Method = null,
    path: ?[]const u8 = null,
    query: ?[]const u8 = null,
    version: ?Version = null,
    headers: Headers = .{},
    header_name_start: usize = 0,
    header_name_end: usize = 0,
    body_start: usize = 0,
    content_length: ?usize = null,
    header_count: usize = 0,

    // Security limits
    limits: Limits = .{},

    pub const Limits = struct {
        max_uri_length: usize = 8 * 1024, // 8KB
        max_header_size: usize = 8 * 1024, // 8KB per header
        max_headers: usize = 100,
        max_body_size: usize = 1024 * 1024, // 1MB
    };

    pub const Version = enum {
        http_1_0,
        http_1_1,
    };

    pub const State = enum {
        method,
        path,
        query,
        version,
        version_lf,
        header_name,
        header_name_colon,
        header_value_start,
        header_value,
        header_lf,
        headers_end_lf,
        body,
        done,
    };

    pub const Error = error{
        InvalidMethod,
        InvalidPath,
        InvalidVersion,
        InvalidHeader,
        HeaderTooLarge,
        TooManyHeaders,
        UriTooLong,
        BodyTooLarge,
        Overflow,
        Incomplete,
    };

    pub const Result = struct {
        method: Method,
        path: []const u8,
        query: ?[]const u8,
        version: Version,
        headers: *const Headers,
        body: ?[]const u8,
    };

    /// Initialize parser with custom limits.
    pub fn initWithLimits(limits: Limits) Parser {
        return .{ .limits = limits };
    }

    /// Parse HTTP request from buffer.
    /// Returns Error.Incomplete if more data needed.
    pub fn parse(self: *Parser, buffer: []const u8) Error!Result {
        while (self.pos < buffer.len) {
            const c = buffer[self.pos];

            switch (self.state) {
                .method => {
                    if (c == ' ') {
                        self.method = Method.parse(buffer[self.mark..self.pos]) orelse
                            return error.InvalidMethod;
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .path;
                    } else {
                        self.pos += 1;
                    }
                },

                .path => {
                    // Check URI length limit
                    if (self.pos - self.mark > self.limits.max_uri_length) {
                        return error.UriTooLong;
                    }
                    if (c == ' ') {
                        self.path = buffer[self.mark..self.pos];
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .version;
                    } else if (c == '?') {
                        self.path = buffer[self.mark..self.pos];
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .query;
                    } else {
                        self.pos += 1;
                    }
                },

                .query => {
                    // Check URI length limit (path + query)
                    if (self.pos - self.mark > self.limits.max_uri_length) {
                        return error.UriTooLong;
                    }
                    if (c == ' ') {
                        self.query = buffer[self.mark..self.pos];
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .version;
                    } else {
                        self.pos += 1;
                    }
                },

                .version => {
                    if (c == '\r') {
                        const version_str = buffer[self.mark..self.pos];
                        if (std.mem.eql(u8, version_str, "HTTP/1.1")) {
                            self.version = .http_1_1;
                        } else if (std.mem.eql(u8, version_str, "HTTP/1.0")) {
                            self.version = .http_1_0;
                        } else {
                            return error.InvalidVersion;
                        }
                        self.pos += 1;
                        self.state = .version_lf;
                    } else {
                        self.pos += 1;
                    }
                },

                .version_lf => {
                    if (c == '\n') {
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .header_name;
                    } else {
                        return error.InvalidVersion;
                    }
                },

                .header_name => {
                    if (c == '\r') {
                        // End of headers
                        self.pos += 1;
                        self.state = .headers_end_lf;
                    } else if (c == ':') {
                        self.header_name_start = self.mark;
                        self.header_name_end = self.pos;
                        self.pos += 1;
                        self.state = .header_name_colon;
                    } else {
                        self.pos += 1;
                    }
                },

                .header_name_colon => {
                    if (c == ' ') {
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .header_value;
                    } else {
                        self.mark = self.pos;
                        self.state = .header_value;
                    }
                },

                .header_value_start => {
                    if (c == ' ') {
                        self.pos += 1;
                    } else {
                        self.mark = self.pos;
                        self.state = .header_value;
                    }
                },

                .header_value => {
                    // Check header size limit
                    const header_size = (self.header_name_end - self.header_name_start) + (self.pos - self.mark);
                    if (header_size > self.limits.max_header_size) {
                        return error.HeaderTooLarge;
                    }

                    if (c == '\r') {
                        const name = buffer[self.header_name_start..self.header_name_end];
                        const value = buffer[self.mark..self.pos];

                        // Check header count limit
                        self.header_count += 1;
                        if (self.header_count > self.limits.max_headers) {
                            return error.TooManyHeaders;
                        }

                        self.headers.add(name, value);

                        // Check for Content-Length and validate against max_body_size
                        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                            const len = std.fmt.parseInt(usize, value, 10) catch 0;
                            if (len > self.limits.max_body_size) {
                                return error.BodyTooLarge;
                            }
                            self.content_length = len;
                        }

                        self.pos += 1;
                        self.state = .header_lf;
                    } else {
                        self.pos += 1;
                    }
                },

                .header_lf => {
                    if (c == '\n') {
                        self.pos += 1;
                        self.mark = self.pos;
                        self.state = .header_name;
                    } else {
                        return error.InvalidHeader;
                    }
                },

                .headers_end_lf => {
                    if (c == '\n') {
                        self.pos += 1;
                        self.body_start = self.pos;

                        if (self.content_length) |len| {
                            if (len > 0) {
                                self.state = .body;
                            } else {
                                self.state = .done;
                            }
                        } else {
                            self.state = .done;
                        }
                    } else {
                        return error.InvalidHeader;
                    }
                },

                .body => {
                    if (self.content_length) |len| {
                        // Use checked arithmetic to prevent overflow
                        const body_end = std.math.add(usize, self.body_start, len) catch {
                            return error.Overflow;
                        };
                        if (buffer.len >= body_end) {
                            self.pos = body_end;
                            self.state = .done;
                        } else {
                            return error.Incomplete;
                        }
                    }
                },

                .done => break,
            }
        }

        if (self.state != .done) {
            return error.Incomplete;
        }

        const body: ?[]const u8 = if (self.content_length) |len|
            if (len > 0) buffer[self.body_start..][0..len] else null
        else
            null;

        return .{
            .method = self.method.?,
            .path = self.path.?,
            .query = self.query,
            .version = self.version.?,
            .headers = &self.headers,
            .body = body,
        };
    }

    pub fn reset(self: *Parser) void {
        self.* = .{};
    }

    /// Get bytes consumed so far
    pub fn bytesConsumed(self: *const Parser) usize {
        return self.pos;
    }
};

test "parse simple GET request" {
    const request = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";

    var parser = Parser{};
    const result = try parser.parse(request);

    try std.testing.expectEqual(Method.GET, result.method);
    try std.testing.expectEqualStrings("/hello", result.path);
    try std.testing.expectEqual(@as(?[]const u8, null), result.query);
    try std.testing.expectEqual(Parser.Version.http_1_1, result.version);
    try std.testing.expectEqualStrings("localhost", result.headers.get("Host").?);
    try std.testing.expectEqual(@as(?[]const u8, null), result.body);
}

test "parse request with query string" {
    const request = "GET /search?q=hello&page=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";

    var parser = Parser{};
    const result = try parser.parse(request);

    try std.testing.expectEqual(Method.GET, result.method);
    try std.testing.expectEqualStrings("/search", result.path);
    try std.testing.expectEqualStrings("q=hello&page=1", result.query.?);
}

test "parse POST with body" {
    const request = "POST /users HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\n{\"name\":\"Jo\"}";

    var parser = Parser{};
    const result = try parser.parse(request);

    try std.testing.expectEqual(Method.POST, result.method);
    try std.testing.expectEqualStrings("/users", result.path);
    try std.testing.expectEqualStrings("{\"name\":\"Jo\"}", result.body.?);
}

test "incomplete request" {
    const partial = "GET /hello HTTP/1.1\r\n";

    var parser = Parser{};
    const result = parser.parse(partial);

    try std.testing.expectError(Parser.Error.Incomplete, result);
}
