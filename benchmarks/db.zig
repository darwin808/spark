const std = @import("std");
const spark = @import("spark");

const DbRow = struct {
    id: u32,
    randomNumber: u32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = spark.initWithConfig(allocator, .{
        .port = 9002,
        .max_connections = 10000,
    });
    defer app.deinit();

    _ = app.get("/db", dbHandler);

    try app.listen();
}

fn dbHandler(ctx: *spark.Context) !void {
    ctx.ok(.{
        .id = 1,
        .randomNumber = 42,
    });
}
