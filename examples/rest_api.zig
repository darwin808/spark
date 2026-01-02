const std = @import("std");
const spark = @import("spark");

// Request/Response types
const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
};

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

// In-memory store (use a database in production)
var users: std.AutoHashMap(u32, User) = undefined;
var next_id: u32 = 1;
var store_allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize store
    users = std.AutoHashMap(u32, User).init(allocator);
    defer users.deinit();
    store_allocator = allocator;

    // Create app
    var app = spark.initWithConfig(allocator, .{
        .port = 8080,
    });
    defer app.deinit();

    // Global middleware
    _ = app
        .use(spark.middleware.logger.simple())
        .use(spark.middleware.cors.allowAll());

    // User routes
    _ = app
        .get("/users", listUsers)
        .get("/users/:id", getUser)
        .post("/users", createUser)
        .delete("/users/:id", deleteUser);

    // Health check
    _ = app.get("/health", health);

    std.log.info("REST API server starting on port 8080", .{});
    try app.listen();
}

fn health(ctx: *spark.Context) !void {
    ctx.ok(.{ .status = "ok" });
}

fn listUsers(ctx: *spark.Context) !void {
    var list = std.ArrayList(User).init(ctx.arena);
    var iter = users.valueIterator();
    while (iter.next()) |user| {
        try list.append(user.*);
    }
    ctx.ok(.{ .users = list.items, .count = list.items.len });
}

fn getUser(ctx: *spark.Context) !void {
    const id_str = ctx.param("id") orelse {
        ctx.badRequest("Missing user ID");
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.badRequest("Invalid user ID");
        return;
    };

    if (users.get(id)) |user| {
        ctx.ok(user);
    } else {
        ctx.notFound();
    }
}

fn createUser(ctx: *spark.Context) !void {
    const req = ctx.body(CreateUserRequest) catch {
        ctx.badRequest("Invalid JSON body");
        return;
    };

    // Validation
    var errors = spark.ValidationErrors.init(ctx.arena);

    if (req.name.len == 0) {
        errors.required("name");
    }
    if (req.email.len == 0) {
        errors.required("email");
    } else if (std.mem.indexOf(u8, req.email, "@") == null) {
        errors.invalid("email", "Must be a valid email address");
    }

    if (errors.hasErrors()) {
        ctx.jsonStatus(.unprocessable_entity, errors.toResponse());
        return;
    }

    // Create user
    const user = User{
        .id = next_id,
        .name = store_allocator.dupe(u8, req.name) catch {
            ctx.internalError();
            return;
        },
        .email = store_allocator.dupe(u8, req.email) catch {
            ctx.internalError();
            return;
        },
    };

    users.put(next_id, user) catch {
        ctx.internalError();
        return;
    };
    next_id += 1;

    ctx.created(user);
}

fn deleteUser(ctx: *spark.Context) !void {
    const id_str = ctx.param("id") orelse {
        ctx.badRequest("Missing user ID");
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.badRequest("Invalid user ID");
        return;
    };

    if (users.fetchRemove(id)) |_| {
        ctx.noContent();
    } else {
        ctx.notFound();
    }
}
