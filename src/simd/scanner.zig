const std = @import("std");
const vector = @import("vector.zig");
const ops = @import("ops.zig");

const Vec = vector.Vec;
const VectorWidth = vector.VectorWidth;

/// High-level buffer scanner using SIMD operations.
/// Provides efficient searching for delimiters in byte buffers.
pub const Scanner = struct {
    data: []const u8,

    /// Initialize a scanner for the given data buffer.
    pub fn init(data: []const u8) Scanner {
        return .{ .data = data };
    }

    /// Find first occurrence of a byte starting at offset.
    /// Returns absolute position in data, or null if not found.
    pub fn findByte(self: *const Scanner, start: usize, needle: u8) ?usize {
        if (start >= self.data.len) return null;

        var pos = start;
        const data = self.data;

        // Process full vectors
        while (pos + VectorWidth <= data.len) {
            const chunk = ops.loadAt(data, pos);
            if (ops.findByte(chunk, needle)) |offset| {
                return pos + offset;
            }
            pos += VectorWidth;
        }

        // Handle tail (scalar fallback for remaining bytes)
        return self.scalarFindByte(pos, needle);
    }

    /// Find first occurrence of either of two bytes.
    /// Returns absolute position in data, or null if not found.
    pub fn findAnyOf2(self: *const Scanner, start: usize, a: u8, b: u8) ?usize {
        if (start >= self.data.len) return null;

        var pos = start;
        const data = self.data;

        // Process full vectors
        while (pos + VectorWidth <= data.len) {
            const chunk = ops.loadAt(data, pos);
            if (ops.findAnyOf2(chunk, a, b)) |offset| {
                return pos + offset;
            }
            pos += VectorWidth;
        }

        // Handle tail
        return self.scalarFindAnyOf2(pos, a, b);
    }

    /// Find first occurrence of any of three bytes.
    /// Returns absolute position in data, or null if not found.
    pub fn findAnyOf3(self: *const Scanner, start: usize, a: u8, b: u8, c: u8) ?usize {
        if (start >= self.data.len) return null;

        var pos = start;
        const data = self.data;

        // Process full vectors
        while (pos + VectorWidth <= data.len) {
            const chunk = ops.loadAt(data, pos);
            if (ops.findAnyOf3(chunk, a, b, c)) |offset| {
                return pos + offset;
            }
            pos += VectorWidth;
        }

        // Handle tail
        return self.scalarFindAnyOf3(pos, a, b, c);
    }

    /// Find CRLF (\r\n) sequence starting at offset.
    /// Returns position of CR (the \r), or null if not found.
    pub fn findCRLF(self: *const Scanner, start: usize) ?usize {
        var pos = start;

        while (self.findByte(pos, '\r')) |cr_pos| {
            if (ops.isCRLF(self.data, cr_pos)) {
                return cr_pos;
            }
            pos = cr_pos + 1;
        }

        return null;
    }

    /// Find double CRLF (\r\n\r\n) sequence - end of HTTP headers.
    /// Returns position of first CR, or null if not found.
    pub fn findDoubleCRLF(self: *const Scanner, start: usize) ?usize {
        var pos = start;

        while (self.findCRLF(pos)) |cr_pos| {
            // Check if followed by another CRLF
            if (cr_pos + 3 < self.data.len and
                self.data[cr_pos + 2] == '\r' and
                self.data[cr_pos + 3] == '\n')
            {
                return cr_pos;
            }
            pos = cr_pos + 2; // Skip past \r\n
        }

        return null;
    }

    // ========================================================================
    // Scalar fallback functions for tail processing
    // ========================================================================

    fn scalarFindByte(self: *const Scanner, start: usize, needle: u8) ?usize {
        var pos = start;
        while (pos < self.data.len) {
            if (self.data[pos] == needle) return pos;
            pos += 1;
        }
        return null;
    }

    fn scalarFindAnyOf2(self: *const Scanner, start: usize, a: u8, b: u8) ?usize {
        var pos = start;
        while (pos < self.data.len) {
            const c = self.data[pos];
            if (c == a or c == b) return pos;
            pos += 1;
        }
        return null;
    }

    fn scalarFindAnyOf3(self: *const Scanner, start: usize, a: u8, b: u8, c: u8) ?usize {
        var pos = start;
        while (pos < self.data.len) {
            const ch = self.data[pos];
            if (ch == a or ch == b or ch == c) return pos;
            pos += 1;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Scanner.findByte - basic" {
    const scanner = Scanner.init("GET /hello HTTP/1.1\r\n");
    try std.testing.expectEqual(@as(?usize, 3), scanner.findByte(0, ' '));
    try std.testing.expectEqual(@as(?usize, 10), scanner.findByte(4, ' '));
}

test "Scanner.findByte - not found" {
    const scanner = Scanner.init("hello");
    try std.testing.expectEqual(@as(?usize, null), scanner.findByte(0, ' '));
}

test "Scanner.findByte - at vector boundary" {
    // Create buffer where target is at position VectorWidth-1
    var buf: [VectorWidth * 2]u8 = undefined;
    @memset(&buf, 'x');
    buf[VectorWidth - 1] = ' ';

    const scanner = Scanner.init(&buf);
    try std.testing.expectEqual(@as(?usize, VectorWidth - 1), scanner.findByte(0, ' '));
}

test "Scanner.findByte - in tail" {
    // Buffer smaller than vector width
    const scanner = Scanner.init("GET ");
    try std.testing.expectEqual(@as(?usize, 3), scanner.findByte(0, ' '));
}

test "Scanner.findByte - exactly at tail start" {
    // Target is first byte of tail region
    var buf: [VectorWidth + 3]u8 = undefined;
    @memset(&buf, 'x');
    buf[VectorWidth] = ' ';

    const scanner = Scanner.init(&buf);
    try std.testing.expectEqual(@as(?usize, VectorWidth), scanner.findByte(0, ' '));
}

test "Scanner.findAnyOf2 - finds first match" {
    const scanner = Scanner.init("/hello?world ");
    // Should find '?' at position 6
    try std.testing.expectEqual(@as(?usize, 6), scanner.findAnyOf2(0, ' ', '?'));
}

test "Scanner.findAnyOf2 - finds space" {
    const scanner = Scanner.init("/hello world");
    try std.testing.expectEqual(@as(?usize, 6), scanner.findAnyOf2(0, ' ', '?'));
}

test "Scanner.findCRLF - basic" {
    const scanner = Scanner.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
    try std.testing.expectEqual(@as(?usize, 15), scanner.findCRLF(0));
    try std.testing.expectEqual(@as(?usize, 34), scanner.findCRLF(17));
}

test "Scanner.findCRLF - CR without LF" {
    const scanner = Scanner.init("hello\rworld\r\n");
    // First \r at 5 is not followed by \n, so should find \r at 11
    try std.testing.expectEqual(@as(?usize, 11), scanner.findCRLF(0));
}

test "Scanner.findDoubleCRLF - end of headers" {
    const scanner = Scanner.init("Host: localhost\r\n\r\nbody");
    try std.testing.expectEqual(@as(?usize, 15), scanner.findDoubleCRLF(0));
}

test "Scanner.findDoubleCRLF - not found" {
    const scanner = Scanner.init("Host: localhost\r\nMore: headers\r\n");
    try std.testing.expectEqual(@as(?usize, null), scanner.findDoubleCRLF(0));
}

test "Scanner - large buffer crossing multiple vectors" {
    // Create a buffer that spans multiple vector widths
    var buf: [VectorWidth * 4]u8 = undefined;
    @memset(&buf, 'x');
    buf[VectorWidth * 3 + 5] = ' '; // Target in 4th vector

    const scanner = Scanner.init(&buf);
    try std.testing.expectEqual(@as(?usize, VectorWidth * 3 + 5), scanner.findByte(0, ' '));
}
