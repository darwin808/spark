const std = @import("std");
const Context = @import("context.zig").Context;

pub const Handler = *const fn (*Context) anyerror!void;
pub const Middleware = Handler;

/// Execute a middleware chain followed by a handler.
pub fn executeChain(
    ctx: *Context,
    global_middleware: []const Middleware,
    handler: Handler,
) !void {
    // Execute global middleware
    for (global_middleware) |mw| {
        try mw(ctx);
        if (!ctx._next_called) return;
        ctx._next_called = false;
    }

    // Execute handler
    try handler(ctx);
}

/// Wrap a handler with middleware at comptime.
pub fn wrap(comptime handler: Handler, comptime middleware: []const Middleware) Handler {
    return struct {
        fn wrapped(ctx: *Context) anyerror!void {
            inline for (middleware) |mw| {
                try mw(ctx);
                if (!ctx._next_called) return;
                ctx._next_called = false;
            }
            try handler(ctx);
        }
    }.wrapped;
}
