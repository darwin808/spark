const std = @import("std");
const builtin = @import("builtin");

/// Compile-time vector width selection based on target architecture.
/// Returns the optimal SIMD width in bytes for the current platform.
pub const VectorWidth: comptime_int = blk: {
    const cpu = builtin.cpu;

    // x86-64: Prefer AVX2 (32 bytes) if available, else SSE2 (16 bytes)
    if (cpu.arch == .x86_64) {
        if (std.Target.x86.featureSetHas(cpu.features, .avx2)) {
            break :blk 32;
        }
        // SSE2 is baseline for x86-64
        break :blk 16;
    }

    // ARM64: NEON provides 128-bit vectors (16 bytes)
    if (cpu.arch == .aarch64) {
        break :blk 16;
    }

    // Fallback for other architectures
    break :blk 16;
};

/// The SIMD vector type for byte operations.
pub const Vec = @Vector(VectorWidth, u8);

/// Boolean mask type for comparison results.
pub const Mask = @Vector(VectorWidth, bool);

/// Integer type for bitmask representation.
pub const MaskInt = std.meta.Int(.unsigned, VectorWidth);

/// Check if SIMD is effectively available (vector width >= 16).
pub const simd_available = VectorWidth >= 16;

test "vector width is reasonable" {
    try std.testing.expect(VectorWidth == 16 or VectorWidth == 32);
}

test "Vec type is correct size" {
    try std.testing.expectEqual(@sizeOf(Vec), VectorWidth);
}
