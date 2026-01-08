const std = @import("std");
pub const Parser = @import("parser.zig").Parser;
pub const Serializer = @import("serializer.zig").Serializer;
pub const FastSerializer = @import("fast_serializer.zig").FastSerializer;
const serializer = @import("serializer.zig");
const fast_serializer = @import("fast_serializer.zig");

/// Parse JSON string into type T.
pub fn parse(comptime T: type, input: []const u8, allocator: std.mem.Allocator) Parser.Error!T {
    var parser = Parser.init(input, allocator);
    return parser.parse(T);
}

/// Serialize value to JSON string.
pub fn stringify(allocator: std.mem.Allocator, value: anytype) Serializer.Error![]const u8 {
    return serializer.stringify(allocator, value);
}

/// Serialize value to a fixed buffer.
pub fn stringifyBuf(buffer: []u8, value: anytype) ![]const u8 {
    return serializer.stringifyBuf(buffer, value);
}

test "json module" {
    const User = struct {
        name: []const u8,
        age: u32,
    };

    // Parse
    const input = "{\"name\":\"Test\",\"age\":25}";
    const user = try parse(User, input, std.testing.allocator);

    try std.testing.expectEqualStrings("Test", user.name);
    try std.testing.expectEqual(@as(u32, 25), user.age);

    // Stringify
    const json = try stringify(std.testing.allocator, user);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"name\":\"Test\",\"age\":25}", json);
}
