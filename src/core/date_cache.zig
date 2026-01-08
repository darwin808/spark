const std = @import("std");

/// Cached HTTP Date header value, updated once per second.
/// Thread-safe for concurrent reads; update() should be called from main loop.
pub const DateCache = struct {
    buffer: [30]u8 = undefined,
    len: u8 = 0,
    last_second: i64 = 0,

    /// Get the current HTTP date string.
    pub fn get(self: *const DateCache) []const u8 {
        if (self.len == 0) return "";
        return self.buffer[0..self.len];
    }

    /// Update the cache if the second has changed.
    /// Cheap check - only formats when timestamp changes.
    pub fn update(self: *DateCache) void {
        const now = std.time.timestamp();
        if (now == self.last_second) return;
        self.last_second = now;
        self.len = @intCast(formatHttpDate(@intCast(now), &self.buffer));
    }

    /// Format HTTP date: "Sun, 06 Nov 1994 08:49:37 GMT"
    fn formatHttpDate(timestamp: u64, buf: *[30]u8) usize {
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = timestamp };
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_secs.getDaySeconds();

        const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        // Jan 1 1970 was Thursday (day 0 = Thursday, index 0 in weekdays)
        const wday: usize = @intCast(@mod(epoch_day.day, 7));

        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        w.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            weekdays[wday],
            month_day.day_index + 1,
            months[month_day.month.numeric() - 1],
            year_day.year,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        }) catch return 0;
        return fbs.pos;
    }
};

/// Global date cache instance.
pub var global: DateCache = .{};

// ============================================================================
// Tests
// ============================================================================

test "DateCache - format produces valid HTTP date" {
    var cache = DateCache{};
    cache.update();

    const date_str = cache.get();
    // Should be 29 characters: "Sun, 06 Nov 1994 08:49:37 GMT"
    try std.testing.expect(date_str.len == 29);

    // Check format: day name
    try std.testing.expect(date_str[3] == ',');
    try std.testing.expect(date_str[4] == ' ');

    // Check GMT suffix
    try std.testing.expect(std.mem.endsWith(u8, date_str, "GMT"));
}

test "DateCache - update is idempotent within same second" {
    var cache = DateCache{};
    cache.update();
    const first = cache.last_second;
    const first_str = cache.get();

    // Multiple updates within same second should be no-ops
    cache.update();
    cache.update();

    try std.testing.expectEqual(first, cache.last_second);
    try std.testing.expectEqualStrings(first_str, cache.get());
}

test "DateCache - known timestamp produces correct date" {
    var buf: [30]u8 = undefined;
    // Unix timestamp 0 = Thu, 01 Jan 1970 00:00:00 GMT
    const len = DateCache.formatHttpDate(0, &buf);
    const result = buf[0..len];
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", result);
}

test "DateCache - another known timestamp" {
    var buf: [30]u8 = undefined;
    // Unix timestamp 784111777 = Sun, 06 Nov 1994 08:49:37 GMT
    const len = DateCache.formatHttpDate(784111777, &buf);
    const result = buf[0..len];
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", result);
}
