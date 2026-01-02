const std = @import("std");

/// Pre-allocated buffer pool for connection handling.
/// Uses a lock-free stack for fast acquire/release.
pub const BufferPool = struct {
    buffers: []Buffer,
    free_stack: std.atomic.Value(?*Node),
    node_pool: []Node,
    allocator: std.mem.Allocator,
    buffer_size: usize,

    pub const Buffer = struct {
        data: []u8,
        index: usize,
    };

    const Node = struct {
        next: ?*Node,
        buffer_index: usize,
    };

    pub fn init(allocator: std.mem.Allocator, pool_size: usize, buffer_size: usize) !BufferPool {
        const buffers = try allocator.alloc(Buffer, pool_size);
        errdefer allocator.free(buffers);

        const nodes = try allocator.alloc(Node, pool_size);
        errdefer allocator.free(nodes);

        // Pre-allocate all buffers
        for (buffers, 0..) |*buf, i| {
            buf.data = try allocator.alloc(u8, buffer_size);
            buf.index = i;
        }

        var pool = BufferPool{
            .buffers = buffers,
            .free_stack = .{ .raw = null },
            .node_pool = nodes,
            .allocator = allocator,
            .buffer_size = buffer_size,
        };

        // Initialize free stack with all buffers
        for (0..pool_size) |i| {
            pool.pushFree(i);
        }

        return pool;
    }

    fn pushFree(self: *BufferPool, index: usize) void {
        const node = &self.node_pool[index];
        node.buffer_index = index;

        while (true) {
            const head = self.free_stack.load(.acquire);
            node.next = head;

            if (self.free_stack.cmpxchgWeak(
                head,
                node,
                .release,
                .monotonic,
            ) == null) {
                return;
            }
        }
    }

    /// Acquire a buffer from the pool. Returns null if pool is exhausted.
    pub fn acquire(self: *BufferPool) ?*Buffer {
        while (true) {
            const head = self.free_stack.load(.acquire) orelse return null;

            if (self.free_stack.cmpxchgWeak(
                head,
                head.next,
                .release,
                .monotonic,
            ) == null) {
                return &self.buffers[head.buffer_index];
            }
        }
    }

    /// Release a buffer back to the pool.
    pub fn release(self: *BufferPool, buffer: *Buffer) void {
        self.pushFree(buffer.index);
    }

    /// Get pool statistics.
    pub fn stats(self: *BufferPool) Stats {
        var free_count: usize = 0;
        var node = self.free_stack.load(.acquire);
        while (node) |n| {
            free_count += 1;
            node = n.next;
        }

        return .{
            .total = self.buffers.len,
            .free = free_count,
            .in_use = self.buffers.len - free_count,
            .buffer_size = self.buffer_size,
        };
    }

    pub const Stats = struct {
        total: usize,
        free: usize,
        in_use: usize,
        buffer_size: usize,
    };

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers) |buf| {
            self.allocator.free(buf.data);
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.node_pool);
    }
};

test "buffer pool basic usage" {
    var pool = try BufferPool.init(std.testing.allocator, 4, 1024);
    defer pool.deinit();

    const s = pool.stats();
    try std.testing.expectEqual(@as(usize, 4), s.total);
    try std.testing.expectEqual(@as(usize, 4), s.free);
    try std.testing.expectEqual(@as(usize, 0), s.in_use);

    // Acquire all buffers
    var bufs: [4]*BufferPool.Buffer = undefined;
    for (&bufs) |*b| {
        b.* = pool.acquire().?;
    }

    const s2 = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), s2.free);
    try std.testing.expectEqual(@as(usize, 4), s2.in_use);

    // Pool exhausted
    try std.testing.expectEqual(@as(?*BufferPool.Buffer, null), pool.acquire());

    // Release one
    pool.release(bufs[0]);

    const s3 = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), s3.free);

    // Can acquire again
    const buf = pool.acquire().?;
    try std.testing.expectEqual(@as(usize, 1024), buf.data.len);
}
