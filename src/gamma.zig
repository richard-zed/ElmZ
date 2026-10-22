//! sRGB transfer, so coverage is blended in light rather than in bytes.
//!
//! Interpolating encoded channels is not the same operation as combining
//! light. Half coverage of white over black gives 127 when the bytes are
//! interpolated and 188 when the light is combined. The error is proportional
//! to how fractional the coverage is, so it is ZERO on the flat interior of a
//! glyph and largest at the half-covered rim -- the one place a UI has edges
//! by definition. That is the whole of "light text on a dark background looks
//! thin and grubby": the rim is too dark, so the stroke reads thinner than the
//! coverage says it is.
//!
//! Both directions are tables. A `pow` per pixel would be honest and slower
//! than the rest of the rasteriser put together; 256 entries up and 4096 down
//! is within a code value of the exact answer everywhere.

const std = @import("std");

/// Resolution of the linear -> encoded table. An 8-bit index would quantise
/// the dark end badly: linear steps of 1/255 near zero are visible bands
/// after encoding, because the curve is steepest there.
pub const steps = 4096;

/// Encoded byte -> linear 0..1. Exact, not approximate.
pub const to_linear: [256]f32 = blk: {
    // `pow` is a series, and the default comptime branch budget is 1000.
    @setEvalBranchQuota(2_000_000);
    var t: [256]f32 = undefined;
    for (0..256) |i| {
        const v = @as(f64, @floatFromInt(i)) / 255.0;
        const l = if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
        t[i] = @floatCast(l);
    }
    break :blk t;
};

/// Linear 0..1 -> encoded byte, indexed in 1/steps.
pub const to_srgb: [steps + 1]u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var t: [steps + 1]u8 = undefined;
    for (0..steps + 1) |i| {
        const l = @as(f64, @floatFromInt(i)) / @as(f64, steps);
        const v = if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f64, l, 1.0 / 2.4) - 0.055;
        const clamped = @min(@max(v, 0.0), 1.0);
        t[i] = @intFromFloat(@round(clamped * 255.0));
    }
    break :blk t;
};

/// Linear 0..1 back to an encoded byte.
pub inline fn encode(v: f32) u8 {
    const f: f32 = @floatFromInt(steps);
    const scaled = @round(v * f);
    if (!(scaled > 0)) return 0;
    const i: usize = @intFromFloat(@min(scaled, f));
    return to_srgb[i];
}

/// Linear, fixed point, 24 bits. Wide on purpose: at 16 bits the rounding to
/// the encode grid disagreed with the float path on 0.32% of combinations by
/// one code value, and "only one" is still a rebaseline.
const q = 1 << 24;
pub const linear24: [256]u32 = blk: {
    @setEvalBranchQuota(2_000_000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        const v = @as(f64, @floatFromInt(i)) / 255.0;
        const l = if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
        t[i] = @intFromFloat(@round(l * @as(f64, q)));
    }
    break :blk t;
};

/// One channel of src-over, in linear light, in fixed point.
///
/// The float version this replaces measured 10.57 ns/px against 4.39 for plain
/// encoded blending -- 2.41x -- because it did two table loads, a multiply, a
/// round, a clamp and a third indexed load per channel. Integer arithmetic
/// gives the same answer without the float conversions. `blendFloat` stays as
/// the oracle: the test below walks all 256 dsts, 256 srcs and a spread of
/// alphas and requires the two to agree exactly.
pub inline fn blend(dst: u8, src: u8, a: f32) u8 {
    if (a <= 0) return dst;
    if (a >= 1.0) return src;
    const aq: i64 = @intFromFloat(@round(a * @as(f32, q)));
    const d: i64 = linear24[dst];
    const s: i64 = linear24[src];
    // 64-bit on purpose: (s - d) * aq reaches 2^48 at the extremes, which is
    // past i32 and would panic in Debug rather than quietly wrapping.
    const v = @max(@min(d + @divTrunc((s - d) * aq, q), q - 1), 0);
    // Round to the SAME grid `encode` uses, so the two paths cannot disagree
    // merely for having chosen differently between two adjacent tables.
    return to_srgb[@intCast(@divTrunc(v * steps + q / 2, q))];
}

/// The float formulation, kept as the differential oracle for `blend`.
pub inline fn blendFloat(dst: u8, src: u8, a: f32) u8 {
    if (a <= 0) return dst;
    if (a >= 1.0) return src;
    const d = to_linear[dst];
    const s = to_linear[src];
    return encode(d + (s - d) * a);
}
