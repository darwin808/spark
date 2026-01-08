const std = @import("std");
const spark = @import("spark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = spark.initWithConfig(allocator, .{
        .port = 9000,
        .max_connections = 10000,
        .num_workers = 8, // Explicitly use 8 workers
    });
    defer app.deinit();

    _ = app.get("/plaintext", plaintext);

    try app.listen();
}

fn plaintext(ctx: *spark.Context) !void {
    ctx.text("Hello, World!");
}
