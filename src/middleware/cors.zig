const std = @import("std");
const Context = @import("../core/context.zig").Context;
const Status = @import("../http/status.zig").Status;

pub const Config = struct {
    origins: []const []const u8 = &.{"*"},
    methods: []const u8 = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    headers: []const u8 = "Content-Type, Authorization",
    expose_headers: ?[]const u8 = null,
    credentials: bool = false,
    max_age: u32 = 86400,
};

/// Create CORS middleware with custom configuration.
pub fn cors(config: Config) *const fn (*Context) anyerror!void {
    return struct {
        fn handler(ctx: *Context) anyerror!void {
            const origin = ctx.header("Origin") orelse {
                ctx.next();
                return;
            };

            // Check if origin is allowed
            var allowed = false;
            for (config.origins) |o| {
                if (std.mem.eql(u8, o, "*") or std.mem.eql(u8, o, origin)) {
                    allowed = true;
                    break;
                }
            }

            if (!allowed) {
                ctx.next();
                return;
            }

            // Set CORS headers
            _ = ctx.setHeader("Access-Control-Allow-Origin", origin);

            if (config.credentials) {
                _ = ctx.setHeader("Access-Control-Allow-Credentials", "true");
            }

            // Handle preflight request
            if (ctx.request.method == .OPTIONS) {
                _ = ctx.setHeader("Access-Control-Allow-Methods", config.methods);
                _ = ctx.setHeader("Access-Control-Allow-Headers", config.headers);

                var buf: [16]u8 = undefined;
                const max_age = std.fmt.bufPrint(&buf, "{d}", .{config.max_age}) catch "86400";
                _ = ctx.setHeader("Access-Control-Max-Age", max_age);

                _ = ctx.status(.no_content);
                ctx.response.written = true;
                return;
            }

            if (config.expose_headers) |expose| {
                _ = ctx.setHeader("Access-Control-Expose-Headers", expose);
            }

            ctx.next();
        }
    }.handler;
}

/// Simple CORS middleware that allows all origins.
pub fn allowAll() *const fn (*Context) anyerror!void {
    return cors(.{});
}

/// Create CORS middleware for specific origins.
pub fn allowOrigins(origins: []const []const u8) *const fn (*Context) anyerror!void {
    return cors(.{ .origins = origins });
}
