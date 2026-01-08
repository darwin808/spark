# Spark

[![CI](https://github.com/darwin808/spark/actions/workflows/ci.yml/badge.svg)](https://github.com/darwin808/spark/actions/workflows/ci.yml)

A fast, lightweight web framework for Zig with Express.js-style ergonomics.

```zig
const spark = @import("spark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = spark.init(allocator);
    defer app.deinit();

    _ = app.get("/", hello);

    try app.listen(); // Starts on port 3000
}

fn hello(ctx: *spark.Context) !void {
    ctx.ok(.{ .message = "Hello, World!" });
}
```

## Features

- **Blazing fast** - SIMD-accelerated HTTP parsing, io_uring (Linux) / kqueue (macOS)
- **Zero-copy parsing** - HTTP headers and body parsed without allocation
- **Type-safe JSON** - Automatic serialization/deserialization using Zig's comptime reflection
- **Express-style routing** - Familiar `.get()`, `.post()`, `.put()`, `.delete()` API
- **Middleware support** - Built-in logger, CORS, and easy custom middleware
- **Multi-threaded** - Thread-per-core model with SO_REUSEPORT load balancing
- **Production-ready security** - Request size limits, header limits, DoS protection

## Requirements

- Zig 0.13.0 or later
- Linux or macOS

## Installation

```bash
# Create a new project
mkdir my-app && cd my-app
zig init

# Add Spark as a dependency
zig fetch --save "git+https://github.com/darwin808/spark#v0.4.0"
```

Then add to your `build.zig`:

```zig
const spark = b.dependency("spark", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("spark", spark.module("spark"));
```

<details>
<summary>Full build.zig example</summary>

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spark = b.dependency("spark", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("spark", spark.module("spark"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

</details>

## Quick Start

Create `src/main.zig`:

```zig
const std = @import("std");
const spark = @import("spark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = spark.init(allocator);
    defer app.deinit();

    _ = app.get("/", index);

    try app.listen();
}

fn index(ctx: *spark.Context) !void {
    ctx.ok(.{ .message = "Welcome to Spark!" });
}
```

Run it:

```bash
zig build run
# Visit http://localhost:3000
```

---

## Guide

### Routing

Spark supports all common HTTP methods:

```zig
_ = app
    .get("/users", listUsers)        // GET
    .post("/users", createUser)      // POST
    .put("/users/:id", updateUser)   // PUT
    .delete("/users/:id", deleteUser) // DELETE
    .patch("/users/:id", patchUser); // PATCH
```

**Route parameters** are prefixed with `:` and captured automatically:

```zig
// Route: /users/:id/posts/:postId
fn getPost(ctx: *spark.Context) !void {
    const user_id = ctx.param("id") orelse return ctx.badRequest("Missing id");
    const post_id = ctx.param("postId") orelse return ctx.badRequest("Missing postId");

    ctx.ok(.{ .userId = user_id, .postId = post_id });
}
```

**Query parameters** are parsed from the URL:

```zig
// URL: /search?q=zig&page=2
fn search(ctx: *spark.Context) !void {
    const query = ctx.query("q") orelse "default";
    const page = ctx.query("page") orelse "1";

    ctx.ok(.{ .query = query, .page = page });
}
```

### Handlers

Handlers receive a `Context` pointer and return `!void`:

```zig
fn myHandler(ctx: *spark.Context) !void {
    // Your code here
    ctx.ok(.{ .success = true });
}
```

The `Context` provides everything you need:

| Method | Description |
|--------|-------------|
| `ctx.param("name")` | Get route parameter |
| `ctx.query("name")` | Get query parameter |
| `ctx.body(Type)` | Parse JSON body into struct |
| `ctx.header("Name")` | Get request header |
| `ctx.rawBody()` | Get raw body bytes |

### Responses

Spark makes responses simple:

```zig
// JSON responses (most common)
ctx.ok(.{ .user = user });           // 200 OK
ctx.created(.{ .id = new_id });       // 201 Created
ctx.noContent();                      // 204 No Content

// Error responses
ctx.badRequest("Invalid input");      // 400
ctx.unauthorized("Please log in");    // 401
ctx.forbidden("Access denied");       // 403
ctx.notFound();                       // 404
ctx.internalError();                  // 500

// Custom status with JSON
ctx.jsonStatus(.accepted, .{ .queued = true });

// Plain text and HTML
ctx.text("Hello, World!");
ctx.html("<h1>Hello</h1>");

// Set headers
ctx.setHeader("X-Custom", "value").ok(.{});
```

### JSON Handling

Spark automatically handles JSON using Zig's type system.

**Parsing request body:**

```zig
const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
    age: ?u32 = null,  // Optional field with default
};

fn createUser(ctx: *spark.Context) !void {
    const req = ctx.body(CreateUserRequest) catch {
        ctx.badRequest("Invalid JSON");
        return;
    };

    // req.name, req.email, req.age are now typed values
    ctx.created(.{ .name = req.name, .email = req.email });
}
```

**Sending responses:**

Just pass any struct - Spark serializes it automatically:

```zig
const User = struct {
    id: u32,
    name: []const u8,
    active: bool,
};

fn getUser(ctx: *spark.Context) !void {
    const user = User{ .id = 1, .name = "Alice", .active = true };
    ctx.ok(user);
    // Response: {"id":1,"name":"Alice","active":true}
}
```

### Middleware

Middleware runs before your handlers. Call `ctx.next()` to continue the chain:

```zig
fn authMiddleware(ctx: *spark.Context) !void {
    const token = ctx.header("Authorization") orelse {
        ctx.unauthorized("Missing token");
        return;  // Don't call next() - stops the chain
    };

    // Validate token...
    ctx.set([]const u8, "user_id", "123");  // Store data for handlers
    ctx.next();  // Continue to next middleware/handler
}

pub fn main() !void {
    // ... setup ...

    _ = app
        .use(authMiddleware)         // Runs on ALL routes
        .get("/profile", getProfile);
}
```

**Built-in middleware:**

```zig
// Logger - prints request info
_ = app.use(spark.middleware.logger.simple());

// CORS - allows cross-origin requests
_ = app.use(spark.middleware.cors.allowAll());
```

### Configuration

Customize the server with `initWithConfig`:

```zig
var app = spark.initWithConfig(allocator, .{
    .port = 8080,              // Default: 3000
    .host = "0.0.0.0",         // Default: "127.0.0.1"
    .max_connections = 10000,  // Default: 10000

    // Security limits
    .max_body_size = 1024 * 1024,    // 1MB (default)
    .max_header_size = 8 * 1024,     // 8KB per header (default)
    .max_headers = 100,              // Max header count (default)
    .max_query_params = 100,         // Max query params (default)
    .read_timeout_ms = 10000,        // 10s read timeout (default)
});
```

### Error Handling

Handlers can return errors - Spark sends a 500 response automatically:

```zig
fn myHandler(ctx: *spark.Context) !void {
    const data = try riskyOperation();  // If this fails, client gets 500
    ctx.ok(data);
}
```

For more control, handle errors explicitly:

```zig
fn myHandler(ctx: *spark.Context) !void {
    const data = riskyOperation() catch |err| {
        std.log.err("Operation failed: {}", .{err});
        ctx.internalError();
        return;
    };
    ctx.ok(data);
}
```

### Validation

Spark includes a validation helper:

```zig
fn createUser(ctx: *spark.Context) !void {
    const req = ctx.body(CreateUserRequest) catch {
        ctx.badRequest("Invalid JSON");
        return;
    };

    var errors = spark.ValidationErrors.init(ctx.arena);

    if (req.name.len == 0) {
        errors.required("name");
    }
    if (req.email.len == 0) {
        errors.required("email");
    } else if (std.mem.indexOf(u8, req.email, "@") == null) {
        errors.invalid("email", "Must be a valid email");
    }

    if (errors.hasErrors()) {
        ctx.jsonStatus(.unprocessable_entity, errors.toResponse());
        return;
    }

    // Validation passed, create user...
}
```

---

## Examples

### Hello World

```bash
zig build run-hello_world
# Visit http://localhost:3000
```

### REST API

A complete CRUD example:

```bash
zig build run-rest_api
```

Test it:

```bash
# List users
curl http://localhost:8080/users

# Create user
curl -X POST http://localhost:8080/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"alice@example.com"}'

# Get user
curl http://localhost:8080/users/1

# Delete user
curl -X DELETE http://localhost:8080/users/1
```

---

## Project Structure

```
spark/
├── src/
│   ├── spark.zig       # Public API - import this
│   ├── core/           # App, router, context, request, response
│   ├── http/           # HTTP parser, methods, status codes
│   ├── json/           # JSON parser and serializer
│   ├── middleware/     # Built-in middleware (cors, logger)
│   └── io/             # Async I/O (io_uring/kqueue)
├── examples/           # Example applications
├── benchmarks/         # Performance benchmarks
└── build.zig           # Build configuration
```

---

## Running Tests

```bash
zig build test
```

---

## Performance

Spark is designed for high performance:

- **Zero-copy parsing** - No allocations during HTTP parsing
- **io_uring (Linux)** - Kernel-level async I/O
- **kqueue (macOS)** - Native event loop
- **Arena allocation** - O(1) cleanup per request

Run benchmarks:

```bash
zig build run-bench-plaintext -Doptimize=ReleaseFast
# Then in another terminal:
wrk -c 256 -d 30 -t 8 http://localhost:9000/plaintext
```

---

## License

MIT

---

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
