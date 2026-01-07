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
        .port = 9003,
        .max_connections = 10000,
    });
    defer app.deinit();

    _ = app.get("/queries", queriesHandler);

    try app.listen();
}

fn queriesHandler(ctx: *spark.Context) !void {
    const n_str = ctx.query("n") orelse "1";
    const n = std.fmt.parseInt(u32, n_str, 10) catch 1;

    // Generate mock rows
    var rows: [20]DbRow = undefined;
    const limit = @min(n, 20);

    for (0..limit) |i| {
        rows[i] = .{
            .id = @intCast(i + 1),
            .randomNumber = 42 + @as(u32, @intCast(i)),
        };
    }

    ctx.ok(rows[0..limit]);
}
