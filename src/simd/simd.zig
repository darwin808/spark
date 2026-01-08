/// SIMD-accelerated operations for high-performance parsing.
///
/// This module provides vectorized byte scanning using platform-specific
/// SIMD instructions (AVX2/SSE2 on x86-64, NEON on ARM64).
///
/// Usage:
/// ```zig
/// const simd = @import("simd/simd.zig");
/// const scanner = simd.Scanner.init(buffer);
/// if (scanner.findByte(0, ' ')) |pos| {
///     // Found space at position `pos`
/// }
/// ```

pub const vector = @import("vector.zig");
pub const ops = @import("ops.zig");
pub const scanner = @import("scanner.zig");

// Re-export commonly used types at top level
pub const Scanner = scanner.Scanner;
pub const Vec = vector.Vec;
pub const Mask = vector.Mask;
pub const VectorWidth = vector.VectorWidth;
pub const simd_available = vector.simd_available;

// Re-export commonly used operations
pub const splat = ops.splat;
pub const findByte = ops.findByte;
pub const findAnyOf2 = ops.findAnyOf2;
pub const findAnyOf3 = ops.findAnyOf3;
pub const isCRLF = ops.isCRLF;
pub const load = ops.load;
pub const loadAt = ops.loadAt;

test {
    // Run all sub-module tests
    _ = vector;
    _ = ops;
    _ = scanner;
}
