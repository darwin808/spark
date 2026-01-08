//! Spark - A blazing fast, noob-friendly web framework for Zig
//!
//! ## Quick Start
//!
//! ```zig
//! const spark = @import("spark");
//!
//! pub fn main() !void {
//!     var app = spark.init(std.heap.page_allocator);
//!     defer app.deinit();
//!
//!     _ = app.get("/", hello);
//!
//!     try app.listen();
//! }
//!
//! fn hello(ctx: *spark.Context) !void {
//!     ctx.ok(.{ .message = "Hello, World!" });
//! }
//! ```

const std = @import("std");

// Core types
pub const Spark = @import("core/app.zig").Spark;
pub const Context = @import("core/context.zig").Context;
pub const Request = @import("core/request.zig").Request;
pub const Response = @import("core/response.zig").Response;
pub const Router = @import("core/router.zig").Router;
pub const RouteGroup = @import("core/router.zig").RouteGroup;
pub const Handler = @import("core/router.zig").Handler;
pub const Middleware = @import("core/router.zig").Middleware;

// HTTP types
pub const Method = @import("http/method.zig").Method;
pub const Status = @import("http/status.zig").Status;
pub const Headers = @import("http/headers.zig").Headers;

// Error types
pub const SparkError = @import("core/errors.zig").SparkError;
pub const ValidationErrors = @import("core/errors.zig").ValidationErrors;

// JSON
pub const json = @import("json/json.zig");

// I/O types (for advanced users)
pub const Io = @import("io/io.zig").Io;
pub const Worker = @import("io/worker.zig").Worker;
pub const WorkerPool = @import("io/worker_pool.zig").WorkerPool;

// SIMD utilities (for advanced users)
pub const simd = @import("simd/simd.zig");

// Built-in middleware
pub const middleware = struct {
    pub const cors = @import("middleware/cors.zig");
    pub const logger = @import("middleware/logger.zig");
    pub const recovery = @import("middleware/recovery.zig");
};

/// Initialize a new Spark application.
pub fn init(allocator: std.mem.Allocator) Spark {
    return Spark.init(allocator);
}

/// Initialize with custom configuration.
pub fn initWithConfig(allocator: std.mem.Allocator, config: Spark.Config) Spark {
    return Spark.initWithConfig(allocator, config);
}

// Tests
test {
    @import("std").testing.refAllDecls(@This());
}

test "http/method" {
    _ = @import("http/method.zig");
}

test "http/status" {
    _ = @import("http/status.zig");
}

test "http/headers" {
    _ = @import("http/headers.zig");
}

test "http/parser" {
    _ = @import("http/parser.zig");
}

test "json" {
    _ = @import("json/json.zig");
    _ = @import("json/parser.zig");
    _ = @import("json/serializer.zig");
}

test "core/router" {
    _ = @import("core/router.zig");
}

test "core/response" {
    _ = @import("core/response.zig");
}

test "memory/allocators" {
    _ = @import("memory/allocators.zig");
}

test "io/buffer_pool" {
    _ = @import("io/buffer_pool.zig");
}

test "simd" {
    _ = @import("simd/simd.zig");
}

test "core/date_cache" {
    _ = @import("core/date_cache.zig");
}
