const std = @import("std");

/// Zero-copy header storage.
/// Stores slices pointing into the raw request buffer.
pub const Headers = struct {
    items: [max_headers]Header = undefined,
    len: usize = 0,

    pub const max_headers = 64;

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn add(self: *Headers, name: []const u8, value: []const u8) void {
        if (self.len >= max_headers) return;
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    pub fn getAll(self: *const Headers, name: []const u8, buf: [][]const u8) [][]const u8 {
        var count: usize = 0;
        for (self.items[0..self.len]) |header| {
            if (count >= buf.len) break;
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                buf[count] = header.value;
                count += 1;
            }
        }
        return buf[0..count];
    }

    pub fn iterator(self: *const Headers) Iterator {
        return .{ .headers = self, .index = 0 };
    }

    pub const Iterator = struct {
        headers: *const Headers,
        index: usize,

        pub fn next(self: *Iterator) ?Header {
            if (self.index >= self.headers.len) return null;
            const header = self.headers.items[self.index];
            self.index += 1;
            return header;
        }
    };

    pub fn reset(self: *Headers) void {
        self.len = 0;
    }
};

test "headers get" {
    var h = Headers{};
    h.add("Content-Type", "application/json");
    h.add("Authorization", "Bearer token");
    h.add("X-Custom", "value1");
    h.add("x-custom", "value2");

    try std.testing.expectEqualStrings("application/json", h.get("Content-Type").?);
    try std.testing.expectEqualStrings("application/json", h.get("content-type").?);
    try std.testing.expectEqual(@as(?[]const u8, null), h.get("X-Missing"));
}
