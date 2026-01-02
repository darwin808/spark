const std = @import("std");
const spark = @import("spark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = spark.init(allocator);
    defer app.deinit();

    // Register routes
    _ = app
        .get("/", hello)
        .get("/health", health)
        .get("/greet/:name", greet);

    // Start server
    try app.listen();
}

fn hello(ctx: *spark.Context) !void {
    ctx.ok(.{
        .message = "Hello, World!",
        .framework = "Spark",
    });
}

fn health(ctx: *spark.Context) !void {
    ctx.ok(.{
        .status = "healthy",
        .uptime = "running",
    });
}

fn greet(ctx: *spark.Context) !void {
    const name = ctx.param("name") orelse "stranger";
    ctx.ok(.{
        .message = "Hello!",
        .name = name,
    });
}
