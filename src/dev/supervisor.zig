const std = @import("std");
const posix = std.posix;
const FileWatcher = @import("watcher.zig").FileWatcher;
const DirWalker = @import("dir_walker.zig").DirWalker;

/// Hot reload supervisor - watches files, rebuilds, and restarts the server.
pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    watcher: FileWatcher,
    walker: DirWalker,
    config: Config,
    child: ?std.process.Child = null,
    last_change: i64 = 0,
    watched_dirs: std.StringHashMap(void),

    pub const Config = struct {
        watch_paths: []const []const u8 = &.{ "src", "examples" },
        extensions: []const []const u8 = &.{".zig"},
        run_target: []const u8,
        debounce_ms: u32 = 100,
        drain_timeout_ms: u32 = 5000,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Supervisor {
        var self = Supervisor{
            .allocator = allocator,
            .watcher = try FileWatcher.init(allocator),
            .walker = DirWalker.init(allocator),
            .config = config,
            .watched_dirs = std.StringHashMap(void).init(allocator),
        };

        // Watch all configured paths
        for (config.watch_paths) |path| {
            self.watchPathRecursive(path) catch |err| {
                std.log.warn("Could not watch {s}: {}", .{ path, err });
            };
        }

        return self;
    }

    fn watchPathRecursive(self: *Supervisor, root: []const u8) !void {
        var dirs = try self.walker.findDirs(root);
        defer self.walker.freeResults(&dirs);

        for (dirs.items) |dir| {
            if (!self.watched_dirs.contains(dir)) {
                try self.watcher.watchDir(dir);
                const dir_copy = try self.allocator.dupe(u8, dir);
                try self.watched_dirs.put(dir_copy, {});
            }
        }
    }

    /// Main run loop - builds, starts server, watches for changes, rebuilds.
    pub fn run(self: *Supervisor) !void {
        self.printBanner();

        // Initial build and start
        if (!try self.rebuild()) {
            self.print("[spark-dev] Initial build failed, waiting for fixes...\n", .{});
        } else {
            try self.startServer();
        }

        // Main watch loop
        while (true) {
            const events = self.watcher.poll(500) catch |err| {
                std.log.err("Watch error: {}", .{err});
                continue;
            };
            defer self.watcher.freeEvents(events);

            if (events.len > 0) {
                // Filter for relevant file changes
                var has_relevant_change = false;
                for (events) |ev| {
                    if (self.isRelevantFile(ev.path)) {
                        self.print("[spark-dev] Changed: {s}\n", .{ev.path});
                        has_relevant_change = true;
                    }
                }

                if (has_relevant_change) {
                    // Debounce - wait for more changes
                    self.last_change = std.time.milliTimestamp();
                }
            }

            // Check if debounce period has passed
            if (self.last_change > 0) {
                const elapsed = std.time.milliTimestamp() - self.last_change;
                if (elapsed >= self.config.debounce_ms) {
                    self.last_change = 0;
                    try self.rebuildAndRestart();
                }
            }

            // Check for new directories periodically
            self.refreshWatches() catch {};
        }
    }

    fn rebuildAndRestart(self: *Supervisor) !void {
        self.print("[spark-dev] Rebuilding...\n", .{});

        // Stop the current server
        if (self.child != null) {
            self.print("[spark-dev] Stopping server...\n", .{});
            self.stopServer();
        }

        // Rebuild
        const start = std.time.milliTimestamp();
        if (try self.rebuild()) {
            const elapsed = std.time.milliTimestamp() - start;
            self.print("[spark-dev] Build complete ({d}ms)\n", .{elapsed});
            try self.startServer();
            self.print("[spark-dev] Server restarted\n", .{});
        } else {
            self.print("[spark-dev] Build failed, waiting for fixes...\n", .{});
        }
    }

    fn rebuild(self: *Supervisor) !bool {
        var child = std.process.Child.init(
            &.{ "zig", "build", self.config.run_target },
            self.allocator,
        );
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;

        try child.spawn();
        const result = try child.wait();

        return result.Exited == 0;
    }

    fn startServer(self: *Supervisor) !void {
        // The run target builds AND runs, so we need to run it
        var child = std.process.Child.init(
            &.{ "zig", "build", self.config.run_target },
            self.allocator,
        );
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;

        try child.spawn();
        self.child = child;
    }

    fn stopServer(self: *Supervisor) void {
        if (self.child) |*child| {
            // Send SIGTERM for graceful shutdown
            const pid = child.id;
            _ = posix.kill(pid, posix.SIG.TERM) catch {};

            // Wait with timeout
            const start = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - start < self.config.drain_timeout_ms) {
                const result = child.wait() catch break;
                switch (result) {
                    .Exited, .Signal, .Stopped, .Unknown => break,
                }
                std.time.sleep(50 * std.time.ns_per_ms);
            }

            // Force kill if still running
            _ = posix.kill(pid, posix.SIG.KILL) catch {};
            _ = child.wait() catch {};

            self.child = null;
        }
    }

    fn isRelevantFile(self: *Supervisor, path: []const u8) bool {
        for (self.config.extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) {
                return true;
            }
        }
        return false;
    }

    fn refreshWatches(self: *Supervisor) !void {
        for (self.config.watch_paths) |path| {
            try self.watchPathRecursive(path);
        }
    }

    fn printBanner(self: *Supervisor) void {
        self.print("\n", .{});
        self.print("  ⚡ spark-dev - Hot Reload Mode\n", .{});
        self.print("  ────────────────────────────────\n", .{});
        self.print("  Watching: ", .{});
        for (self.config.watch_paths, 0..) |p, i| {
            if (i > 0) self.print(", ", .{});
            self.print("{s}/", .{p});
        }
        self.print("\n", .{});
        self.print("  Target:   {s}\n", .{self.config.run_target});
        self.print("\n", .{});
    }

    fn print(_: *Supervisor, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }

    pub fn deinit(self: *Supervisor) void {
        self.stopServer();

        var iter = self.watched_dirs.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.watched_dirs.deinit();

        self.watcher.deinit();
    }
};
