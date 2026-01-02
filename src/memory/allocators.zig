const std = @import("std");

/// Request-scoped arena allocator.
/// Provides fast allocation during request handling with O(1) cleanup.
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) RequestArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset arena for next request - O(1) operation
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }
};

test "request arena basic usage" {
    var arena = RequestArena.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const slice = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice.len);

    arena.reset();

    // Should be able to allocate again after reset
    const slice2 = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice2.len);
}
