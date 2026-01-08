const std = @import("std");
const vector = @import("vector.zig");

pub const Vec = vector.Vec;
pub const Mask = vector.Mask;
pub const MaskInt = vector.MaskInt;
pub const VectorWidth = vector.VectorWidth;

/// Broadcast a single byte to all vector lanes.
pub inline fn splat(byte: u8) Vec {
    return @splat(byte);
}

/// Convert a boolean mask to an integer bitmask.
pub inline fn maskToInt(mask: Mask) MaskInt {
    return @bitCast(mask);
}

/// Find the index of the first true value in a mask.
/// Returns null if no bits are set.
pub inline fn firstTrue(mask: Mask) ?usize {
    const int_mask = maskToInt(mask);
    if (int_mask == 0) return null;
    return @ctz(int_mask);
}

/// Find first occurrence of a byte in a vector.
/// Returns offset from vector start, or null if not found.
pub inline fn findByte(v: Vec, needle: u8) ?usize {
    const mask: Mask = v == splat(needle);
    return firstTrue(mask);
}

/// Find first occurrence of either of two bytes in a vector.
pub inline fn findAnyOf2(v: Vec, a: u8, b: u8) ?usize {
    const mask_a: Mask = v == splat(a);
    const mask_b: Mask = v == splat(b);
    // OR the masks together
    const combined = @select(bool, mask_a, @as(Mask, @splat(true)), mask_b);
    return firstTrue(combined);
}

/// Find first occurrence of any of three bytes in a vector.
pub inline fn findAnyOf3(v: Vec, a: u8, b: u8, c: u8) ?usize {
    const mask_a: Mask = v == splat(a);
    const mask_b: Mask = v == splat(b);
    const mask_c: Mask = v == splat(c);
    // OR all masks together
    const ab = @select(bool, mask_a, @as(Mask, @splat(true)), mask_b);
    const abc = @select(bool, ab, @as(Mask, @splat(true)), mask_c);
    return firstTrue(abc);
}

/// Check if CR at a position is followed by LF.
/// Safe bounds checking included.
pub inline fn isCRLF(data: []const u8, cr_pos: usize) bool {
    return cr_pos + 1 < data.len and data[cr_pos + 1] == '\n';
}

/// Load a vector from a byte slice (unaligned).
pub inline fn load(data: []const u8) Vec {
    return data[0..VectorWidth].*;
}

/// Load a vector from a byte slice at an offset.
pub inline fn loadAt(data: []const u8, offset: usize) Vec {
    return data[offset..][0..VectorWidth].*;
}

// ============================================================================
// Tests
// ============================================================================

test "splat creates uniform vector" {
    const v = splat('x');
    for (0..VectorWidth) |i| {
        try std.testing.expectEqual(@as(u8, 'x'), v[i]);
    }
}

test "findByte - found at start" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    data[0] = ' ';
    const v = load(&data);
    try std.testing.expectEqual(@as(?usize, 0), findByte(v, ' '));
}

test "findByte - found in middle" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    data[7] = ' ';
    const v = load(&data);
    try std.testing.expectEqual(@as(?usize, 7), findByte(v, ' '));
}

test "findByte - found at end" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    data[VectorWidth - 1] = ' ';
    const v = load(&data);
    try std.testing.expectEqual(@as(?usize, VectorWidth - 1), findByte(v, ' '));
}

test "findByte - not found" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    const v = load(&data);
    try std.testing.expectEqual(@as(?usize, null), findByte(v, ' '));
}

test "findAnyOf2 - finds first match" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    data[3] = '?';
    data[5] = ' ';
    const v = load(&data);
    // Should find '?' at position 3 (first match)
    try std.testing.expectEqual(@as(?usize, 3), findAnyOf2(v, ' ', '?'));
}

test "findAnyOf2 - finds second needle" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    data[5] = ' ';
    const v = load(&data);
    try std.testing.expectEqual(@as(?usize, 5), findAnyOf2(v, ' ', '?'));
}

test "findAnyOf3 - finds any of three" {
    var data: [VectorWidth]u8 = undefined;
    @memset(&data, 'x');
    data[4] = ':';
    const v = load(&data);
    try std.testing.expectEqual(@as(?usize, 4), findAnyOf3(v, ' ', '\r', ':'));
}

test "isCRLF - valid sequence" {
    const data = "hello\r\nworld";
    try std.testing.expect(isCRLF(data, 5));
}

test "isCRLF - CR at end of buffer" {
    const data = "hello\r";
    try std.testing.expect(!isCRLF(data, 5));
}

test "isCRLF - CR not followed by LF" {
    const data = "hello\r world";
    try std.testing.expect(!isCRLF(data, 5));
}
