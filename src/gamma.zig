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

/// One channel of src-over, composited in linear light and re-encoded.
pub inline fn blend(dst: u8, src: u8, a: f32) u8 {
    if (a <= 0) return dst;
    if (a >= 1.0) return src;
    const d = to_linear[dst];
    const s = to_linear[src];
    return encode(d + (s - d) * a);
}
