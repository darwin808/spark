const std = @import("std");

/// Comptime-driven JSON serializer.
pub const Serializer = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub const Error = error{OutOfMemory};

    pub fn init(allocator: std.mem.Allocator) Serializer {
        return .{
            .buffer = .{},
            .allocator = allocator,
        };
    }

    pub fn serialize(self: *Serializer, value: anytype) Error!void {
        try self.writeValue(value);
    }

    pub fn toOwnedSlice(self: *Serializer) Error![]const u8 {
        return self.buffer.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    pub fn slice(self: *Serializer) []const u8 {
        return self.buffer.items;
    }

    fn writeValue(self: *Serializer, value: anytype) Error!void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        switch (info) {
            .void, .null => try self.append("null"),
            .bool => try self.append(if (value) "true" else "false"),

            .int, .comptime_int => {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
                try self.append(str);
            },

            .float, .comptime_float => {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
                try self.append(str);
            },

            .optional => {
                if (value) |v| {
                    try self.writeValue(v);
                } else {
                    try self.append("null");
                }
            },

            .pointer => |ptr| {
                switch (ptr.size) {
                    .one => try self.writeValue(value.*),
                    .slice => {
                        if (ptr.child == u8) {
                            try self.writeString(value);
                        } else {
                            try self.appendByte('[');
                            for (value, 0..) |item, i| {
                                if (i > 0) try self.appendByte(',');
                                try self.writeValue(item);
                            }
                            try self.appendByte(']');
                        }
                    },
                    else => try self.append("null"),
                }
            },

            .array => |arr| {
                if (arr.child == u8) {
                    try self.writeString(&value);
                } else {
                    try self.appendByte('[');
                    for (value, 0..) |item, i| {
                        if (i > 0) try self.appendByte(',');
                        try self.writeValue(item);
                    }
                    try self.appendByte(']');
                }
            },

            .@"struct" => |s| {
                if (s.is_tuple) {
                    try self.appendByte('[');
                    inline for (s.fields, 0..) |field, i| {
                        if (i > 0) try self.appendByte(',');
                        try self.writeValue(@field(value, field.name));
                    }
                    try self.appendByte(']');
                } else {
                    try self.appendByte('{');
                    var first = true;

                    inline for (s.fields) |field| {
                        const field_value = @field(value, field.name);

                        if (@typeInfo(field.type) == .optional) {
                            if (field_value == null) continue;
                        }

                        if (!first) try self.appendByte(',');
                        first = false;

                        try self.writeString(field.name);
                        try self.appendByte(':');
                        try self.writeValue(field_value);
                    }
                    try self.appendByte('}');
                }
            },

            .@"enum" => {
                try self.writeString(@tagName(value));
            },

            else => try self.append("null"),
        }
    }

    fn writeString(self: *Serializer, str: []const u8) Error!void {
        try self.appendByte('"');
        for (str) |c| {
            switch (c) {
                '"' => try self.append("\\\""),
                '\\' => try self.append("\\\\"),
                '\n' => try self.append("\\n"),
                '\r' => try self.append("\\r"),
                '\t' => try self.append("\\t"),
                else => try self.appendByte(c),
            }
        }
        try self.appendByte('"');
    }

    fn append(self: *Serializer, str: []const u8) Error!void {
        self.buffer.appendSlice(self.allocator, str) catch return error.OutOfMemory;
    }

    fn appendByte(self: *Serializer, byte: u8) Error!void {
        self.buffer.append(self.allocator, byte) catch return error.OutOfMemory;
    }

    pub fn deinit(self: *Serializer) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *Serializer) void {
        self.buffer.clearRetainingCapacity();
    }
};

/// Serialize value to JSON string directly.
pub fn stringify(allocator: std.mem.Allocator, value: anytype) Serializer.Error![]const u8 {
    var serializer = Serializer.init(allocator);
    errdefer serializer.deinit();
    try serializer.serialize(value);
    return serializer.toOwnedSlice();
}

test "serialize simple struct" {
    const User = struct {
        name: []const u8,
        age: u32,
    };

    const user = User{ .name = "John", .age = 30 };
    const json = try stringify(std.testing.allocator, user);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"name\":\"John\",\"age\":30}", json);
}
