//! Coverage ramps over a signed distance field.
//!
//! Cedar hands back `dist`: signed distance to a glyph outline, negative inside
//! the ink and positive outside. What to DO with that is a rendering policy --
//! how thick a stroke looks, where a glow fades, what "inner" means -- and a
//! TrueType parser has no business naming a drop-shadow mode. So the field stays
//! in Cedar and the arithmetic lives here, in a module that depends on neither
//! the font parser nor the canvas.

const std = @import("std");

/// Which side of the contour a halo is drawn on.
pub const HaloMode = enum { glow, outer_glow, inner_glow };

pub fn strokeCoverageAA(field: []const f32, out: []u8, width: u8, aa: f32) void {
    const w: f32 = @as(f32, @floatFromInt(width)) * 0.5;
    const inner = -w;
    if (aa <= 0) {
        for (out, field) |*o, d| o.* = if (d >= inner and d <= w) 255 else 0;
        return;
    }
    // `aa` is the TOTAL ramp width, so it reaches `aa/2` either side. Dividing
    // by `aa` and offsetting by `aa/2` made the ramp `2*aa` wide, drawing a 1px
    // band as roughly 2px.
    const half_aa = @max(aa * 0.5, 1e-4);
    const inv = 1.0 / (half_aa * 2.0);
    for (out, field) |*o, d| {
        // Positive inside the band. `m + half_aa` puts the ramp midpoint ON the
        // boundary, so antialiasing softens edges without widening them.
        const m = @min(w - d, d - inner);
        const c = (m + half_aa) * inv;
        o.* = @intFromFloat(@max(0.0, @min(1.0, c)) * 255.0 + 0.5);
    }
}

/// Halo band, on either side of the contour.
///
/// The field is signed, so `inner_glow` is the same ramp reflected through
/// `d = 0` -- no second rasterisation. `spread` pushes the inner edge off the
/// contour; `offset` slides the profile for a directional shadow.
pub fn haloCoverageAA(
    field: []const f32,
    out: []u8,
    w: u32,
    h: u32,
    radius: f32,
    falloff: f32,
    aa: f32,
    mode: HaloMode,
    spread: f32,
    off_x: f32,
    off_y: f32,
) void {
    if (radius <= 0) {
        @memset(out, 0);
        return;
    }

    const fo = @max(0.0, @min(1.0, falloff));
    const half_aa = @max(aa * 0.5, 1e-4);
    const inv_aa = 1.0 / (half_aa * 2.0);
    const sp = @max(0.0, spread);
    const shape = 1.0 + fo;
    // `offset` TRANSLATES THE GLOW: the field is read at a displaced sample so
    // the contour the ramp sees is the glyph moved by the offset. Subtracting
    // the offset from the distance instead moved the zero-crossing in place,
    // which cut a letter-shaped hole out of the glow -- a glow around a
    // displaced copy rather than a shadow of this one.
    const ix: i32 = @intFromFloat(@round(off_x));
    const iy: i32 = @intFromFloat(@round(off_y));
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const o = &out[@as(usize, row) * w + col];
            const sx = @as(i32, @intCast(col)) - ix;
            const sy = @as(i32, @intCast(row)) - iy;
            if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(w)) or sy >= @as(i32, @intCast(h))) {
                o.* = 0;
                continue;
            }
            const raw = field[@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))];
            // A DISPLACED shape is filled, not ringed. A drop shadow is the
            // silhouette of the thing, moved -- so where the displaced field is
            // ink the shadow is SOLID. Ramping a ring there paints only the
            // shadow's edge and leaves its body empty, which reads as a hollow
            // middle. A centred glow keeps the ring maths: nothing is displaced,
            // so there is no body to fill.
            // The solid body has to HAND OFF to the ramp at full opacity. A hard
            // `raw < 0` test stops filling exactly at the field's zero, but the
            // ramp's own soft edge starts fading there too, so the last column
            // of body and the first column of glow both drop to nothing -- a
            // seam a pixel or two wide. Extend the body by the AA half-width so
            // the two overlap instead of abutting.
            // `spread` grows the shape, so the solid body has to grow with it.
            // Filling only where `raw < 0` left a band `sp` wide that the body
            // had not reached and the ramp had not started -- the gap seen at
            // `.spread = 2`. `sp` is the same term the ramp subtracts, so the
            // body ends exactly where the ramp begins.
            const displaced = ix != 0 or iy != 0;
            if (displaced and mode != .inner_glow and raw < sp + half_aa) {
                o.* = 255;
                continue;
            }
            const d = raw;
            const t_d: f32 = switch (mode) {
                .glow, .outer_glow => d - sp,
                .inner_glow => -d - sp,
            };
            // `.outer_glow` excludes the element's own silhouette so only the
            // rim outside the ink shows. That cut is applied a stage later as a
            // binary test, while the ramp fades through its soft `edge` term --
            // so at the boundary the ramp keeps a partial-alpha pixel that the
            // cut does not remove, and a sub-pixel sliver survives between the
            // glyph and its glow. Cut here instead, on the same signed field,
            // where `d < 0` is genuinely inside the ink.
            // TAKE THE CUT AS THE SAME TAPER THE BOX BAKE USES, not a hard
            // zero. A hard cut deletes the boundary pixel outright, and the
            // glyph's own antialiasing is too thin there to cover it -- which
            // is the dark line between letter and rim.
            //
            // The taper width must be THIS RAMP'S `aa`, not a literal half
            // pixel. The soft `edge` term below fades over `aa`, so a taper of
            // any other width leaves a sliver where one has finished and the
            // other has not. Fading to zero at `-half_aa` makes the two meet.
            const outer_taper: f32 = if (mode == .outer_glow)
                std.math.clamp((d + half_aa) * inv_aa, 0.0, 1.0)
            else
                1.0;
            if (t_d <= 0.0 or t_d >= radius) {
                o.* = 0;
                continue;
            }
            // A NEGATIVE `falloff` is a literal band, not a feathered one: the
            // whole width out to `radius` is solid and only the AA `edge` term
            // softens the inner boundary. A border is exactly this -- a halo
            // with no feathering.
            const a = if (falloff < 0.0)
                outer_taper
            else
                (1.0 - std.math.pow(f32, t_d / radius, shape)) * outer_taper;
            // Soften the contour boundary only: a ramp at the rim would draw a
            // ring exactly where smoothness was asked for.
            // BOTH boundaries ramp. `edge` softens the inner one against the
            // ink; a solid band's OUTER boundary was a hard `t_d >= radius`
            // cull above, which antialiases nothing and reads as stairs on any
            // curve. Mirror the same taper inward from `radius`.
            const outer = @max(0.0, @min(1.0, (radius - t_d + half_aa) * inv_aa));
            const edge = @max(0.0, @min(1.0, (t_d + half_aa) * inv_aa));
            o.* = @intFromFloat(@max(0.0, @min(1.0, @min(a, @min(edge, outer)))) * 255.0 + 0.5);
        }
    }
}
