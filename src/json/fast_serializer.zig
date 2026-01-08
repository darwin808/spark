const std = @import("std");

/// Zero-allocation JSON serializer that writes directly to a fixed buffer.
/// Designed for maximum performance in hot paths.
pub const FastSerializer = struct {
    buffer: []u8,
    pos: usize = 0,

    pub const Error = error{BufferOverflow};

    /// Initialize with a pre-allocated buffer (typically the response write buffer)
    pub fn init(buffer: []u8) FastSerializer {
        return .{ .buffer = buffer };
    }

    /// Reset position for reuse
    pub inline fn reset(self: *FastSerializer) void {
        self.pos = 0;
    }

    /// Get the serialized slice
    pub inline fn slice(self: *const FastSerializer) []const u8 {
        return self.buffer[0..self.pos];
    }

    /// Get current position
    pub inline fn len(self: *const FastSerializer) usize {
        return self.pos;
    }

    /// Serialize any value to JSON
    pub fn serialize(self: *FastSerializer, value: anytype) Error!void {
        try self.writeValue(value);
    }

    fn writeValue(self: *FastSerializer, value: anytype) Error!void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        switch (info) {
            .void, .null => try self.writeRaw("null"),
            .bool => try self.writeRaw(if (value) "true" else "false"),

            .int, .comptime_int => {
                // Fast integer serialization
                var buf: [21]u8 = undefined; // Max i64 is 20 digits + sign
                const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
                try self.writeRaw(str);
            },

            .float, .comptime_float => {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
                try self.writeRaw(str);
            },

            .optional => {
                if (value) |v| {
                    try self.writeValue(v);
                } else {
                    try self.writeRaw("null");
                }
            },

            .pointer => |ptr| {
                switch (ptr.size) {
                    .one => try self.writeValue(value.*),
                    .slice => {
                        if (ptr.child == u8) {
                            try self.writeString(value);
                        } else {
                            try self.writeByte('[');
                            for (value, 0..) |item, i| {
                                if (i > 0) try self.writeByte(',');
                                try self.writeValue(item);
                            }
                            try self.writeByte(']');
                        }
                    },
                    else => try self.writeRaw("null"),
                }
            },

            .array => |arr| {
                if (arr.child == u8) {
                    try self.writeString(&value);
                } else {
                    try self.writeByte('[');
                    for (value, 0..) |item, i| {
                        if (i > 0) try self.writeByte(',');
                        try self.writeValue(item);
                    }
                    try self.writeByte(']');
                }
            },

            .@"struct" => |s| {
                if (s.is_tuple) {
                    try self.writeByte('[');
                    inline for (s.fields, 0..) |field, i| {
                        if (i > 0) try self.writeByte(',');
                        try self.writeValue(@field(value, field.name));
                    }
                    try self.writeByte(']');
                } else {
                    try self.writeByte('{');
                    var first = true;

                    inline for (s.fields) |field| {
                        const field_value = @field(value, field.name);

                        if (@typeInfo(field.type) == .optional) {
                            if (field_value == null) continue;
                        }

                        if (!first) try self.writeByte(',');
                        first = false;

                        try self.writeString(field.name);
                        try self.writeByte(':');
                        try self.writeValue(field_value);
                    }
                    try self.writeByte('}');
                }
            },

            .@"enum" => {
                try self.writeString(@tagName(value));
            },

            else => try self.writeRaw("null"),
        }
    }

    /// Write a JSON string with escaping
    fn writeString(self: *FastSerializer, str: []const u8) Error!void {
        try self.writeByte('"');

        // Fast path: scan for characters that need escaping
        var start: usize = 0;
        for (str, 0..) |c, i| {
            const escape_seq: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };

            if (escape_seq) |seq| {
                // Write unescaped portion
                if (i > start) {
                    try self.writeRaw(str[start..i]);
                }
                try self.writeRaw(seq);
                start = i + 1;
            }
        }

        // Write remaining unescaped portion
        if (start < str.len) {
            try self.writeRaw(str[start..]);
        }

        try self.writeByte('"');
    }

    /// Write raw bytes (no escaping)
    inline fn writeRaw(self: *FastSerializer, data: []const u8) Error!void {
        if (self.pos + data.len > self.buffer.len) return error.BufferOverflow;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    /// Write a single byte
    inline fn writeByte(self: *FastSerializer, byte: u8) Error!void {
        if (self.pos >= self.buffer.len) return error.BufferOverflow;
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }
};

/// Serialize value directly to buffer, return bytes written
pub fn serializeTo(buffer: []u8, value: anytype) FastSerializer.Error!usize {
    var s = FastSerializer.init(buffer);
    try s.serialize(value);
    return s.len();
}

test "fast serialize simple struct" {
    var buffer: [256]u8 = undefined;
    const User = struct {
        id: u32,
        name: []const u8,
        email: []const u8,
    };

    const user = User{ .id = 1, .name = "John", .email = "john@example.com" };
    const len = try serializeTo(&buffer, user);

    try std.testing.expectEqualStrings(
        "{\"id\":1,\"name\":\"John\",\"email\":\"john@example.com\"}",
        buffer[0..len],
    );
}

test "fast serialize nested struct" {
    var buffer: [256]u8 = undefined;
    const Response = struct {
        count: u32,
        message: []const u8,
    };

    const resp = Response{ .count = 100, .message = "Users retrieved" };
    const len = try serializeTo(&buffer, resp);

    try std.testing.expectEqualStrings(
        "{\"count\":100,\"message\":\"Users retrieved\"}",
        buffer[0..len],
    );
}

test "fast serialize escaping" {
    var buffer: [256]u8 = undefined;
    const Data = struct {
        text: []const u8,
    };

    const data = Data{ .text = "hello\nworld\t\"quoted\"" };
    const len = try serializeTo(&buffer, data);

    try std.testing.expectEqualStrings(
        "{\"text\":\"hello\\nworld\\t\\\"quoted\\\"\"}",
        buffer[0..len],
    );
}
