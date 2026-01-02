const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../core/context.zig").Context;
const Status = @import("../http/status.zig").Status;

pub const Config = struct {
    log_errors: bool = true,
    stack_trace: bool = false,
};

/// Create recovery middleware with custom configuration.
pub fn recovery(config: Config) *const fn (*Context) anyerror!void {
    return struct {
        fn handler(ctx: *Context) anyerror!void {
            ctx._next_called = true;

            // The actual error handling happens in the App's request handler
            // This middleware just ensures we continue the chain
            _ = config;
        }
    }.handler;
}

/// Simple recovery middleware.
pub fn simple() *const fn (*Context) anyerror!void {
    return recovery(.{});
}

/// Handle an error that occurred during request processing.
pub fn handleError(ctx: *Context, err: anyerror, config: Config) void {
    if (config.log_errors) {
        std.log.err("Request error: {s} {s} - {}", .{
            ctx.request.method.toString(),
            ctx.request.path,
            err,
        });

        if (config.stack_trace and builtin.mode == .Debug) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        }
    }

    // Send error response if not already written
    if (!ctx.response.written) {
        ctx.internalError();
    }
}
