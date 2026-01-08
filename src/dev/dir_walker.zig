const std = @import("std");

/// Recursively walks directories to find files matching given extensions.
pub const DirWalker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DirWalker {
        return .{ .allocator = allocator };
    }

    /// Recursively find all files with matching extensions in the given root directory.
    /// Returns owned slice of paths - caller must free with freeResults().
    pub fn findFiles(
        self: *DirWalker,
        root: []const u8,
        extensions: []const []const u8,
    ) !std.ArrayList([]const u8) {
        var results = std.ArrayList([]const u8){};
        errdefer self.freeResults(&results);

        try self.walkDir(root, extensions, &results);
        return results;
    }

    /// Find all subdirectories recursively.
    pub fn findDirs(
        self: *DirWalker,
        root: []const u8,
    ) !std.ArrayList([]const u8) {
        var results = std.ArrayList([]const u8){};
        errdefer self.freeResults(&results);

        try self.walkDirsOnly(root, &results);
        return results;
    }

    fn walkDir(
        self: *DirWalker,
        path: []const u8,
        extensions: []const []const u8,
        results: *std.ArrayList([]const u8),
    ) !void {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            // Skip directories we can't open (permissions, etc.)
            if (err == error.AccessDenied or err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            errdefer self.allocator.free(full_path);

            switch (entry.kind) {
                .directory => {
                    // Skip hidden directories and common non-source dirs
                    if (entry.name[0] == '.' or
                        std.mem.eql(u8, entry.name, "zig-out") or
                        std.mem.eql(u8, entry.name, "zig-cache") or
                        std.mem.eql(u8, entry.name, ".zig-cache"))
                    {
                        self.allocator.free(full_path);
                        continue;
                    }
                    try self.walkDir(full_path, extensions, results);
                    self.allocator.free(full_path);
                },
                .file => {
                    if (self.matchesExtension(entry.name, extensions)) {
                        try results.append(self.allocator, full_path);
                    } else {
                        self.allocator.free(full_path);
                    }
                },
                else => {
                    self.allocator.free(full_path);
                },
            }
        }
    }

    fn walkDirsOnly(
        self: *DirWalker,
        path: []const u8,
        results: *std.ArrayList([]const u8),
    ) !void {
        // Add the root itself
        const root_copy = try self.allocator.dupe(u8, path);
        try results.append(self.allocator, root_copy);

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            if (err == error.AccessDenied or err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Skip hidden directories and common non-source dirs
            if (entry.name[0] == '.' or
                std.mem.eql(u8, entry.name, "zig-out") or
                std.mem.eql(u8, entry.name, "zig-cache") or
                std.mem.eql(u8, entry.name, ".zig-cache"))
            {
                continue;
            }

            const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            try self.walkDirsOnly(full_path, results);
            self.allocator.free(full_path);
        }
    }

    fn matchesExtension(self: *DirWalker, filename: []const u8, extensions: []const []const u8) bool {
        _ = self;
        for (extensions) |ext| {
            if (std.mem.endsWith(u8, filename, ext)) {
                return true;
            }
        }
        return false;
    }

    /// Free all paths in a results list.
    pub fn freeResults(self: *DirWalker, results: *std.ArrayList([]const u8)) void {
        for (results.items) |path| {
            self.allocator.free(path);
        }
        results.deinit(self.allocator);
    }
};

test "find zig files" {
    const allocator = std.testing.allocator;
    var walker = DirWalker.init(allocator);

    var results = try walker.findFiles("src", &.{".zig"});
    defer walker.freeResults(&results);

    // Should find at least some .zig files in src/
    try std.testing.expect(results.items.len > 0);

    // All results should end with .zig
    for (results.items) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, ".zig"));
    }
}

test "find directories" {
    const allocator = std.testing.allocator;
    var walker = DirWalker.init(allocator);

    var results = try walker.findDirs("src");
    defer walker.freeResults(&results);

    // Should find at least the root and some subdirs
    try std.testing.expect(results.items.len > 0);

    // First should be "src" itself
    try std.testing.expectEqualStrings("src", results.items[0]);
}
