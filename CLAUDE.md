# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build test                # Run all unit tests
zig build run-hello_world     # Run hello_world example
zig build run-rest_api        # Run rest_api example
```

Requires Zig 0.13.0+. No external dependencies.

## Architecture

Spark is a Zig web framework with Express.js-style ergonomics and zero-copy performance.

### Request Flow

1. **I/O layer** (`src/io/`) - Platform-specific event loop (io_uring on Linux, kqueue on macOS/BSD) accepts connections and manages read/write buffers via connection pooling
2. **HTTP parser** (`src/http/parser.zig`) - Zero-copy state machine parses HTTP/1.1, returning slices into the raw buffer
3. **Router** (`src/core/router.zig`) - Segment-based pattern matching extracts path parameters (`:param`, `*` wildcard)
4. **Middleware chain** (`src/core/middleware.zig`) - Executes global and route-group middleware before handlers
5. **Handler** receives `Context` - Unified interface wrapping request/response with convenience methods
6. **Response serialization** (`src/core/response.zig`) - Builds HTTP/1.1 wire format with automatic Content-Length

### Key Design Decisions

- **Zero-copy throughout**: HTTP parser, headers, request all store slices into the original buffer rather than copying
- **Arena allocation**: `RequestArena` in `src/memory/allocators.zig` provides O(1) reset between requests
- **Fluent API**: Route methods return `*Spark` for chaining (`app.get("/a", h1).post("/b", h2)`)
- **Platform abstraction**: `src/io/io.zig` uses compile-time backend selection via union type

### Module Structure

- `src/spark.zig` - Public API, re-exports all user-facing types
- `src/core/` - App, router, context, request, response, errors, middleware execution
- `src/http/` - Protocol types (method, status, headers) and parser
- `src/json/` - Type-safe JSON parser and serializer
- `src/middleware/` - Built-in middleware (cors, logger, recovery)
- `src/io/` - Async I/O with platform backends and buffer/connection pools
- `src/memory/` - Allocator utilities

### Handler Signature

```zig
fn handler(ctx: *spark.Context) !void {
    const id = ctx.param("id");           // Path parameter
    const user = try ctx.body(User);      // Parse JSON body
    ctx.ok(.{ .user = user });            // JSON response
}
```
