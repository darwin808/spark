const std = @import("std");
const spark = @import("spark");

// Import fast components
const fast_router = spark.core.fast_router;
const fast_response = spark.core.fast_response;
const fast_context = spark.core.fast_context;
const date_cache = spark.core.date_cache;
const HttpParser = spark.http.Parser;
const Request = spark.core.Request;
const Io = spark.Io;

// In-memory storage (simulates database)
var users_mutex: std.Thread.Mutex = .{};
var users: std.AutoHashMap(u32, User) = undefined;
var next_id: u32 = 1;
var allocator_global: std.mem.Allocator = undefined;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
};

// Pre-allocated router (initialized once at startup)
var router: fast_router.FastRouter = undefined;

// Wrapper to convert handler signature
fn wrapHandler(comptime handler: fn (*fast_context.FastContext) anyerror!void) fast_router.Handler {
    return @ptrCast(&struct {
        fn wrapped(ptr: *anyopaque) anyerror!void {
            const ctx: *fast_context.FastContext = @ptrCast(@alignCast(ptr));
            return handler(ctx);
        }
    }.wrapped);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    allocator_global = allocator;

    // Initialize storage
    users = std.AutoHashMap(u32, User).init(allocator);
    defer users.deinit();

    // Seed with some data
    try seedData();

    // Initialize router
    router = fast_router.FastRouter.init(allocator);
    defer router.deinit();

    router.get("/users", wrapHandler(listUsers));
    router.get("/users/:id", wrapHandler(getUser));
    router.post("/users", wrapHandler(createUser));
    router.put("/users/:id", wrapHandler(updateUser));
    router.delete("/users/:id", wrapHandler(deleteUser));

    // Use Spark's I/O layer for proper async handling
    var io = try Io.init(allocator, .{
        .max_connections = 10000,
        .buffer_size = 16 * 1024,
    });
    defer io.deinit();

    const listen_fd = try io.listen("127.0.0.1", 9000);

    std.log.info("Fast CRUD listening on http://127.0.0.1:9000", .{});

    try io.run(listen_fd, handleRequest, null);
}

fn handleRequest(conn: *Io.Connection) void {
    // Update date cache
    date_cache.global.update();

    // Parse HTTP request with default limits
    var parser = HttpParser.initWithLimits(.{});
    const parse_result = parser.parse(conn.readData()) catch |err| {
        switch (err) {
            error.Incomplete => return,
            else => {
                const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
                @memcpy(conn.write_buffer[0..bad_request.len], bad_request);
                conn.write_len = bad_request.len;
                return;
            },
        }
    };

    // Stack-allocated params buffer (zero heap allocation)
    var params: fast_router.ParamBuffer = .{};

    // Fast response (writes directly to buffer)
    var response = fast_response.FastResponse.init(conn.write_buffer);

    // Route matching (zero allocation)
    if (router.match(parse_result.method, parse_result.path, &params)) |handler| {
        // Create minimal request for body parsing
        var request = Request.init(
            parse_result.method,
            parse_result.path,
            parse_result.query,
            parse_result.headers,
            parse_result.body,
            allocator_global,
        );

        // Create context
        var ctx = fast_context.FastContext.init(&request, &response, &params);

        // Call handler
        handler(@ptrCast(&ctx)) catch {
            ctx.internalError();
        };
    } else {
        // Static 404 response
        @memcpy(conn.write_buffer[0..fast_response.STATIC_RESPONSES.not_found.len], fast_response.STATIC_RESPONSES.not_found);
        response.pos = fast_response.STATIC_RESPONSES.not_found.len;
    }

    conn.write_len = response.len();
}

fn seedData() !void {
    users_mutex.lock();
    defer users_mutex.unlock();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try users.put(next_id, .{
            .id = next_id,
            .name = "User",
            .email = "user@example.com",
        });
        next_id += 1;
    }
}

fn listUsers(ctx: *fast_context.FastContext) !void {
    users_mutex.lock();
    defer users_mutex.unlock();

    var count: u32 = 0;
    var iter = users.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    ctx.ok(.{ .count = count, .message = "Users retrieved" });
}

fn getUser(ctx: *fast_context.FastContext) !void {
    const id_str = ctx.param("id") orelse {
        ctx.badRequest("Missing id");
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.badRequest("Invalid id");
        return;
    };

    users_mutex.lock();
    defer users_mutex.unlock();

    if (users.get(id)) |user| {
        ctx.ok(.{ .id = user.id, .name = user.name, .email = user.email });
    } else {
        ctx.notFound();
    }
}

fn createUser(ctx: *fast_context.FastContext) !void {
    const req = ctx.body(CreateUserRequest) catch {
        ctx.badRequest("Invalid JSON");
        return;
    };

    users_mutex.lock();
    defer users_mutex.unlock();

    const id = next_id;
    next_id += 1;

    users.put(id, .{
        .id = id,
        .name = req.name,
        .email = req.email,
    }) catch {
        ctx.internalError();
        return;
    };

    ctx.created(.{ .id = id, .name = req.name, .email = req.email });
}

fn updateUser(ctx: *fast_context.FastContext) !void {
    const id_str = ctx.param("id") orelse {
        ctx.badRequest("Missing id");
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.badRequest("Invalid id");
        return;
    };

    const req = ctx.body(CreateUserRequest) catch {
        ctx.badRequest("Invalid JSON");
        return;
    };

    users_mutex.lock();
    defer users_mutex.unlock();

    if (users.contains(id)) {
        users.put(id, .{
            .id = id,
            .name = req.name,
            .email = req.email,
        }) catch {
            ctx.internalError();
            return;
        };
        ctx.ok(.{ .id = id, .name = req.name, .email = req.email });
    } else {
        ctx.notFound();
    }
}

fn deleteUser(ctx: *fast_context.FastContext) !void {
    const id_str = ctx.param("id") orelse {
        ctx.badRequest("Missing id");
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.badRequest("Invalid id");
        return;
    };

    users_mutex.lock();
    defer users_mutex.unlock();

    if (users.remove(id)) {
        ctx.ok(.{ .deleted = true, .id = id });
    } else {
        ctx.notFound();
    }
}
