const std = @import("std");
const dev = @import("spark-dev");
const Supervisor = dev.Supervisor;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const target = args[1];

    // Validate target format
    if (!std.mem.startsWith(u8, target, "run-")) {
        std.debug.print("Error: Target must start with 'run-' (e.g., run-hello_world)\n\n", .{});
        printUsage();
        return;
    }

    // Create and run supervisor
    var supervisor = try Supervisor.init(allocator, .{
        .run_target = target,
        .watch_paths = &.{ "src", "examples", "benchmarks" },
        .extensions = &.{".zig"},
        .debounce_ms = 100,
    });
    defer supervisor.deinit();

    supervisor.run() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: spark-dev <run-target>
        \\
        \\Arguments:
        \\  <run-target>    The zig build target to run (e.g., run-hello_world)
        \\
        \\Examples:
        \\  spark-dev run-hello_world
        \\  spark-dev run-rest_api
        \\
        \\Or use via zig build:
        \\  zig build dev -- run-hello_world
        \\
    , .{});
}
