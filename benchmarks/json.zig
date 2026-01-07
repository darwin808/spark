const std = @import("std");
const spark = @import("spark");

const Message = struct {
    message: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = spark.initWithConfig(allocator, .{
        .port = 9001,
        .max_connections = 10000,
    });
    defer app.deinit();

    _ = app.get("/json", jsonHandler);

    try app.listen();
}

fn jsonHandler(ctx: *spark.Context) !void {
    ctx.ok(.{ .message = "Hello, World!" });
}
