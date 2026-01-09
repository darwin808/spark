const std = @import("std");
const posix = std.posix;

/// Thread-safe queue for distributing file descriptors from acceptor to workers.
/// Uses a simple ring buffer with mutex protection.
pub const FdQueue = struct {
    buffer: []posix.fd_t,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !FdQueue {
        const buffer = try allocator.alloc(posix.fd_t, capacity);
        return .{
            .buffer = buffer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FdQueue) void {
        self.allocator.free(self.buffer);
    }

    /// Push a file descriptor to the queue. Returns false if queue is full.
    pub fn push(self: *FdQueue, fd: posix.fd_t) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count >= self.buffer.len) {
            return false; // Queue full
        }

        self.buffer[self.tail] = fd;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.count += 1;

        // Signal waiting workers
        self.not_empty.signal();
        return true;
    }

    /// Pop a file descriptor from the queue. Blocks if empty.
    /// Returns null if queue is being shutdown (signaled by closing).
    pub fn pop(self: *FdQueue, timeout_ns: ?u64) ?posix.fd_t {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Wait for item or timeout
        while (self.count == 0) {
            if (timeout_ns) |ns| {
                const result = self.not_empty.timedWait(&self.mutex, ns);
                if (result == .timed_out) return null;
            } else {
                self.not_empty.wait(&self.mutex);
            }
        }

        const fd = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;
        return fd;
    }

    /// Non-blocking pop. Returns null if queue is empty.
    pub fn tryPop(self: *FdQueue) ?posix.fd_t {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count == 0) return null;

        const fd = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;
        return fd;
    }

    /// Wake all waiting threads (for shutdown).
    pub fn wakeAll(self: *FdQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.not_empty.broadcast();
    }
};

/// Round-robin distributor for multiple queues.
pub const FdDistributor = struct {
    queues: []*FdQueue,
    current: std.atomic.Value(usize),

    pub fn init(queues: []*FdQueue) FdDistributor {
        return .{
            .queues = queues,
            .current = std.atomic.Value(usize).init(0),
        };
    }

    /// Distribute a file descriptor to the next worker in round-robin fashion.
    pub fn distribute(self: *FdDistributor, fd: posix.fd_t) bool {
        const num_queues = self.queues.len;
        var attempts: usize = 0;

        while (attempts < num_queues) {
            const idx = self.current.fetchAdd(1, .monotonic) % num_queues;
            if (self.queues[idx].push(fd)) {
                return true;
            }
            attempts += 1;
        }

        return false; // All queues full
    }
};
