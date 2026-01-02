const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    CONNECT,
    TRACE,

    pub fn parse(bytes: []const u8) ?Method {
        return switch (bytes.len) {
            3 => switch (bytes[0]) {
                'G' => if (std.mem.eql(u8, bytes, "GET")) .GET else null,
                'P' => if (std.mem.eql(u8, bytes, "PUT")) .PUT else null,
                else => null,
            },
            4 => switch (bytes[0]) {
                'P' => if (std.mem.eql(u8, bytes, "POST")) .POST else null,
                'H' => if (std.mem.eql(u8, bytes, "HEAD")) .HEAD else null,
                else => null,
            },
            5 => switch (bytes[0]) {
                'P' => if (std.mem.eql(u8, bytes, "PATCH")) .PATCH else null,
                'T' => if (std.mem.eql(u8, bytes, "TRACE")) .TRACE else null,
                else => null,
            },
            6 => if (std.mem.eql(u8, bytes, "DELETE")) .DELETE else null,
            7 => switch (bytes[0]) {
                'O' => if (std.mem.eql(u8, bytes, "OPTIONS")) .OPTIONS else null,
                'C' => if (std.mem.eql(u8, bytes, "CONNECT")) .CONNECT else null,
                else => null,
            },
            else => null,
        };
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .CONNECT => "CONNECT",
            .TRACE => "TRACE",
        };
    }
};

test "parse method" {
    try std.testing.expectEqual(Method.GET, Method.parse("GET"));
    try std.testing.expectEqual(Method.POST, Method.parse("POST"));
    try std.testing.expectEqual(Method.PUT, Method.parse("PUT"));
    try std.testing.expectEqual(Method.DELETE, Method.parse("DELETE"));
    try std.testing.expectEqual(Method.PATCH, Method.parse("PATCH"));
    try std.testing.expectEqual(Method.HEAD, Method.parse("HEAD"));
    try std.testing.expectEqual(Method.OPTIONS, Method.parse("OPTIONS"));
    try std.testing.expectEqual(@as(?Method, null), Method.parse("INVALID"));
}
