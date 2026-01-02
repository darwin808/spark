const std = @import("std");
const Context = @import("../core/context.zig").Context;

pub const Format = enum {
    tiny,
    short,
    combined,
};

pub const Config = struct {
    format: Format = .tiny,
    skip_paths: []const []const u8 = &.{},
};

/// Create logger middleware with custom configuration.
pub fn logger(config: Config) *const fn (*Context) anyerror!void {
    return struct {
        fn handler(ctx: *Context) anyerror!void {
            // Check if path should be skipped
            for (config.skip_paths) |skip| {
                if (std.mem.eql(u8, ctx.request.path, skip)) {
                    ctx.next();
                    return;
                }
            }

            const start = std.time.milliTimestamp();

            // Call next handler
            ctx.next();

            const end = std.time.milliTimestamp();
            const duration = end - start;

            switch (config.format) {
                .tiny => {
                    std.log.info("{s} {s} {d} {d}ms", .{
                        ctx.request.method.toString(),
                        ctx.request.path,
                        ctx.response.status.code(),
                        duration,
                    });
                },
                .short => {
                    std.log.info("{s} {s} {d} {d}ms - {s}", .{
                        ctx.request.method.toString(),
                        ctx.request.path,
                        ctx.response.status.code(),
                        duration,
                        ctx.header("User-Agent") orelse "-",
                    });
                },
                .combined => {
                    const remote = ctx.header("X-Forwarded-For") orelse "-";
                    const user_agent = ctx.header("User-Agent") orelse "-";
                    const referer = ctx.header("Referer") orelse "-";

                    std.log.info("{s} \"{s} {s}\" {d} \"{s}\" \"{s}\" {d}ms", .{
                        remote,
                        ctx.request.method.toString(),
                        ctx.request.path,
                        ctx.response.status.code(),
                        referer,
                        user_agent,
                        duration,
                    });
                },
            }
        }
    }.handler;
}

/// Simple logger with tiny format.
pub fn simple() *const fn (*Context) anyerror!void {
    return logger(.{});
}

/// Logger with combined format (Apache-style).
pub fn combined() *const fn (*Context) anyerror!void {
    return logger(.{ .format = .combined });
}
