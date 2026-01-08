const std = @import("std");
const spark = @import("spark");

// In-memory storage (simulates database)
var users_mutex: std.Thread.Mutex = .{};
var users: std.AutoHashMap(u32, User) = undefined;
var next_id: u32 = 1;
var initialized: bool = false;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize storage
    users = std.AutoHashMap(u32, User).init(allocator);
    defer users.deinit();
    initialized = true;

    // Seed with some data
    try seedData();

    var app = spark.initWithConfig(allocator, .{
        .port = 9000,
        .max_connections = 10000,
        .num_workers = 1, // Single-threaded for fair comparison
    });
    defer app.deinit();

    _ = app
        .get("/users", listUsers)
        .get("/users/:id", getUser)
        .post("/users", createUser)
        .put("/users/:id", updateUser)
        .delete("/users/:id", deleteUser);

    try app.listen();
}

fn seedData() !void {
    users_mutex.lock();
    defer users_mutex.unlock();

    // Add 100 initial users
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

fn listUsers(ctx: *spark.Context) !void {
    users_mutex.lock();
    defer users_mutex.unlock();

    // Return count and first few IDs
    var count: u32 = 0;
    var iter = users.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    ctx.ok(.{ .count = count, .message = "Users retrieved" });
}

fn getUser(ctx: *spark.Context) !void {
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

fn createUser(ctx: *spark.Context) !void {
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

fn updateUser(ctx: *spark.Context) !void {
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

fn deleteUser(ctx: *spark.Context) !void {
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
