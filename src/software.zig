//! Software backend for elmz: an RGB framebuffer with a 5x7 bitmap font, plus a
//! dependency-free PNG encoder. This is the backend you want while you are
//! still arguing with layout; swap in a GPU backend later behind the same
//! `elmz.Renderer` vtable.

const std = @import("std");
const elmz = @import("elmz");
const ttf = @import("ttf.zig");
const Allocator = std.mem.Allocator;

/// Falloff width at a pixel, given a light direction.
///
/// A rounded rect's outward normal is axis aligned, so the width only needs to
/// know which edge is nearest -- which the half-extent terms already answer. The
/// dot product against the cast direction then says whether this edge faces the
/// light (narrow) or away from it (wide). Guarded by a floor so a grazing light
/// cannot collapse the ramp to nothing.
fn lightWidth(blur: f32, px: f32, py: f32, hx: f32, hy: f32, cast: [2]f32) f32 {
    // Outside-ness per axis, positive outside the half-extent. The GOVERNING axis
    // is the one further out, and the normal points from the centre toward this
    // pixel on that axis. Comparing the abs'd offsets instead gets the mid-edge
    // case exactly backwards: at x = centre the horizontal term is a large negative
    // (deep inside) and would win the comparison, naming a side normal at a pixel
    // that is above the shape.
    const ox = @abs(px) - hx;
    const oy = @abs(py) - hy;
    const x_governs = ox >= oy;
    const nx: f32 = if (x_governs) (if (px < 0) -1 else 1) else 0;
    const ny: f32 = if (x_governs) 0 else (if (py < 0) -1 else 1);
    const f: f32 = std.math.clamp(1.0 + 0.65 * (nx * cast[0] + ny * cast[1]), 0.15, 2.0);
    return blur * f;
}

/// The one ramp, for every mode: coverage is opaque well inside the silhouette,
/// half at the edge, gone well outside. `d` is the signed distance from that
/// silhouette, negative inside. `mode` picks which side survives and, for an
/// inner glow, which DIRECTION the falloff runs.
///
/// Shared by the distance-field path and the stencil bake on purpose. A mode that
/// meant two things depending on which path drew it would be two features wearing
/// one name.
fn ramp(mode: elmz.Halo.Mode, d: f32, blur: f32, core: f32) f32 {
    if (blur <= 0) return 1;
    return switch (mode) {
        // Both halves. `.outer_glow` is the same ramp: what makes it outer is
        // being cut against the ELEMENT's silhouette (see `haloSdf`), not against
        // the shape the ramp was built from. Cutting against the shape leaves a
        // hole exactly where an offset shadow should be visible -- the strip of
        // backdrop between the element's edge and the offset silhouette.
        .glow, .outer_glow => std.math.clamp(0.5 - d / blur, 0, 1),
        // Its own curve, not the shared one mirrored. Mirrored it cannot exceed
        // HALF, because the shared ramp is half-opaque AT the silhouette by
        // construction -- right for a glow straddling an edge, wrong for a rim
        // light that lives entirely inside it. That ceiling, not the falloff, is
        // why the mirrored version read as a smudge.
        //
        // Full at the edge, gone a whole `blur` inward: twice the peak and twice
        // the reach of the mirrored form.
        // Squared, and that is the whole shape of it: drop away fast from the edge,
        // then converge gently instead of arriving.
        //
        // A linear ramp fails both halves. It holds its brightness most of the way
        // in and then terminates, which reads as a band with a hard inner edge --
        // most of the falloff spent where it is invisible, none of it where the eye
        // needs it. `(1-u)^2` is steepest AT the edge (three quarters of the
        // brightness is gone by the halfway point) and flattens as it runs out, so
        // the tail approaches the face colour rather than stopping on it.
        //
        // A soft-at-both-ends curve (`(1-u^2)^2`) was tried and is the wrong way
        // round: peak brightness with zero slope at the boundary is a plateau, not a
        // rim, and the face reads flat.
        // `core` is the flat part of the rim: full brightness for that many pixels
        // before the decay starts. It is subtracted from the depth AFTER the sign
        // test above, because adding it to `d` instead makes the boundary pixel
        // read as "outside" and switches the rim off right where it should be
        // brightest -- which is exactly how the first attempt failed.
        .inner_glow => if (d > 0) 0 else blk: {
            const u = std.math.clamp((-d - core) / blur, 0, 1);
            const left = 1.0 - u;
            break :blk left * left;
        },
    };
}

/// How much a rim light should stop tracing the outline and hug the inscribed
/// ellipse instead.
///
/// Zero for a narrow rim: it is tracing the shape, and the corners are part of
/// what you see. A distance field inverts that as it widens -- inward offsets
/// SHRINK the corner radius (`r - t`), so a glow at half the short side has
/// driven the corners to zero and what it draws is a rectangle of sharp
/// corners, not a softened button. Past that point the outline is not
/// legible anyway: the band from each edge has met in the middle, and the only
/// remaining question is whether the light looks like the shape or like a pool
/// of it. This says "like a pool", from half the short side upward.
fn circularity(w: f32, h: f32, blur: f32) f32 {
    const short = @min(w, h);
    if (short <= 0 or blur <= 0) return 0;
    return std.math.clamp(blur / (short * 0.5) - 0.5, 0, 1);
}

/// Distance to an ellipse, to first order.
///
/// The normalised radius says how far out you are and its gradient says how
/// fast that changes, so dividing one by the other converts to pixels. Exact on
/// both axes, and within a pixel of the true distance at the 45 degree corner
/// (14.1 vs ~12.6 on an 80x60 box) -- which is ample for a soft ramp.
fn ellipseDistance(px: f32, py: f32, a: f32, b: f32) f32 {
    const ia = if (a > 0) 1.0 / a else 0;
    const ib = if (b > 0) 1.0 / b else 0;
    const gx = px * ia;
    const gy = py * ib;
    const g = @sqrt(gx * gx + gy * gy);
    if (g <= 0) return -@min(a, b);
    const grad = @sqrt(gx * gx * ia * ia + gy * gy * ib * ib) / g;
    if (grad <= 0) return -@min(a, b);
    return (g - 1) / grad;
}

/// How far a ramp reaches from the silhouette, in pixels, WITHOUT the extra
/// pixel that covers the antialiased edge.
///
/// The shared ramp dies `blur / 2` either side of the edge; a lit one reaches
/// `blur` on the side it is thrown toward; an inner glow dies a full `blur` in.
/// Every walk band and every mask is sized from this, because a band narrower
/// than the ramp silently clips its own falloff -- which is exactly what a
/// longer inner ramp would do at the old `blur / 2`.
fn falloffReach(mode: elmz.Halo.Mode, blur: f32, lit: bool) f32 {
    if (mode == .inner_glow) return blur;
    return blur * (if (lit) @as(f32, 1.0) else 0.5);
}

/// One separable box pass over an RGBA buffer, in place. `rad` is the half-width
/// in pixels and sampling clamps at the edges, so a blur never pulls colour from
/// outside the region it was handed.
///
/// Integer sums and a sliding window: one add and one subtract per pixel per
/// channel rather than `2 * rad + 1` of them, which is what keeps three passes
/// affordable on a whole card. `scratch` is `max(w, h) * 4` bytes, reused by
/// every pass.
fn boxBlur(buf: []u8, w: usize, h: usize, rad: usize, horizontal: bool, scratch: []u8) void {
    const lines = if (horizontal) h else w;
    const len = if (horizontal) w else h;
    if (rad == 0 or len == 0 or lines == 0) return;
    const step: usize = if (horizontal) 4 else w * 4;
    const win: u32 = @intCast(2 * rad + 1);
    const n_i: isize = @intCast(len);
    const rad_i: isize = @intCast(rad);

    var l: usize = 0;
    while (l < lines) : (l += 1) {
        const base = if (horizontal) l * w * 4 else l * 4;
        var sum = [4]u32{ 0, 0, 0, 0 };
        var k: isize = -rad_i;
        while (k <= rad_i) : (k += 1) {
            const ci: usize = @intCast(std.math.clamp(k, 0, n_i - 1));
            const o = base + ci * step;
            sum[0] += buf[o];
            sum[1] += buf[o + 1];
            sum[2] += buf[o + 2];
            sum[3] += buf[o + 3];
        }
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const so = i * 4;
            scratch[so] = @intCast(sum[0] / win);
            scratch[so + 1] = @intCast(sum[1] / win);
            scratch[so + 2] = @intCast(sum[2] / win);
            scratch[so + 3] = @intCast(sum[3] / win);
            const i_i: isize = @intCast(i);
            const rem: usize = @intCast(std.math.clamp(i_i - rad_i, 0, n_i - 1));
            const add: usize = @intCast(std.math.clamp(i_i + rad_i + 1, 0, n_i - 1));
            const ro = base + rem * step;
            const ao = base + add * step;
            sum[0] = sum[0] - buf[ro] + buf[ao];
            sum[1] = sum[1] - buf[ro + 1] + buf[ao + 1];
            sum[2] = sum[2] - buf[ro + 2] + buf[ao + 2];
            sum[3] = sum[3] - buf[ro + 3] + buf[ao + 3];
        }
        // Written back after the whole line is read, because the sliding window
        // reads the pixel it is about to replace.
        i = 0;
        while (i < len) : (i += 1) {
            const o = base + i * step;
            const so = i * 4;
            buf[o] = scratch[so];
            buf[o + 1] = scratch[so + 1];
            buf[o + 2] = scratch[so + 2];
            buf[o + 3] = scratch[so + 3];
        }
    }
}

pub const Canvas = struct {
    const Self = @This();

    gpa: Allocator,
    w: u32,
    h: u32,
    px: []u8, // RGBA8

    /// A baked halo is a stencil: coverage per pixel for one silhouette, tinted
    /// at blit. Keyed on geometry only, so changing a halo's colour never
    /// invalidates it -- which is the entire reason to bake rather than ramp
    /// the distance field every frame.
    masks: std.ArrayListUnmanaged(Mask) = .empty,

    /// How many stencils have been BAKED, as opposed to found in the cache.
    /// Nothing in the renderer reads this -- it exists so a benchmark can tell
    /// a cache hit from a re-bake. A cache hit is not evidence about dispatch,
    /// and neither is a timing.
    bakes: usize = 0,

    const Mask = struct {
        /// Shape size this stencil was baked at. `sw == 0` marks a SLICE
        /// TEMPLATE, which stands in for every size at its radius and blur.
        sw: i32,
        sh: i32,
        r: f32,
        blur: f32,
        /// Which side of the silhouette this stencil carries. Part of the key,
        /// because the same geometry bakes to three different pictures.
        mode: elmz.Halo.Mode = .glow,
        /// Template only: width of the corner band, in pixels.
        corner: u32 = 0,
        rw: u32,
        rh: u32,
        px: []u8 = &.{}, // coverage, one byte per pixel; set by `admit`
    };

    pub fn init(gpa: Allocator, w: u32, h: u32) !Self {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .gpa = gpa, .w = w, .h = h, .px = px };
    }

    pub fn deinit(self: *Self) void {
        for (self.masks.items) |m| self.gpa.free(m.px);
        self.masks.deinit(self.gpa);
        self.gpa.free(self.px);
    }

    pub fn clear(self: *Self, color: elmz.Color) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            self.px[i + 0] = color.r;
            self.px[i + 1] = color.g;
            self.px[i + 2] = color.b;
            self.px[i + 3] = 255;
        }
    }

    fn blendPixel(self: *Self, x: i64, y: i64, color: elmz.Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.w or uy >= self.h) return;
        const i = (@as(usize, uy) * self.w + ux) * 4;
        // Opaque is not a special case for correctness -- src-over with a=255
        // is an identity -- it is a special case for TIME: it is what nearly
        // every pixel in a UI does, and discovering the identity costs four
        // float conversions and a divide per pixel.
        if (color.a == 255) {
            self.px[i + 0] = color.r;
            self.px[i + 1] = color.g;
            self.px[i + 2] = color.b;
            // Alpha is written here too, and it is not decoration: src-over onto
            // a cleared canvas leaves the destination at 0 when the source only
            // covers it partly, so an entire frame painted with opaque colours
            // would export as a fully TRANSPARENT PNG -- correct RGB, invisible
            // everywhere except a test that compares channels.
            self.px[i + 3] = 255;
            return;
        }
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        const dst_r: f32 = @floatFromInt(self.px[i + 0]);
        const dst_g: f32 = @floatFromInt(self.px[i + 1]);
        const dst_b: f32 = @floatFromInt(self.px[i + 2]);
        self.px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * a + dst_r * (1 - a));
        self.px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * a + dst_g * (1 - a));
        self.px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * a + dst_b * (1 - a));
    }

    /// One scanline in one colour. The blend coefficients are hoisted out of
    /// the loop, which is the whole point of a row fill: the source colour is
    /// constant along the row, so converting it to float 640 times was 640
    /// times too many.
    fn fillRow(self: *Self, x0: i64, x1: i64, y: u32, color: elmz.Color) void {
        if (color.a == 0) return;
        const row = @as(usize, y) * self.w;
        var x: usize = @intCast(x0);
        const end: usize = @intCast(x1);
        if (color.a == 255) {
            while (x < end) : (x += 1) {
                const i = (row + x) * 4;
                self.px[i + 0] = color.r;
                self.px[i + 1] = color.g;
                self.px[i + 2] = color.b;
                self.px[i + 3] = 255;
            }
            return;
        }
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        const inv = 1.0 - a;
        const sr = @as(f32, @floatFromInt(color.r)) * a;
        const sg = @as(f32, @floatFromInt(color.g)) * a;
        const sb = @as(f32, @floatFromInt(color.b)) * a;
        while (x < end) : (x += 1) {
            const i = (row + x) * 4;
            self.px[i + 0] = @intFromFloat(sr + @as(f32, @floatFromInt(self.px[i + 0])) * inv);
            self.px[i + 1] = @intFromFloat(sg + @as(f32, @floatFromInt(self.px[i + 1])) * inv);
            self.px[i + 2] = @intFromFloat(sb + @as(f32, @floatFromInt(self.px[i + 2])) * inv);
        }
    }

    const Span = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

    /// Integer pixel span of `rect` after clipping, or null when nothing is
    /// left. Both bounds are resolved before the loop, so the per-pixel path
    /// is exactly what it was when nothing clips.
    fn clipSpan(self: *Self, rect: elmz.Rect, clip: elmz.Rect) ?Span {
        // Edges are taken straight from the two rects rather than from
        // `intersect`, whose width is `x1 - x0`. That subtraction is not
        // always exact in f32, and re-deriving `x1` from it could move an
        // edge by one pixel. Copied this way, an unbounded clip reproduces
        // the unclipped arithmetic bit for bit.
        const cx0 = @max(rect.x, clip.x);
        const cy0 = @max(rect.y, clip.y);
        const cx1 = @min(rect.x + rect.w, clip.x + clip.w);
        const cy1 = @min(rect.y + rect.h, clip.y + clip.h);
        if (!(cx1 > cx0 and cy1 > cy0)) return null;
        const w_i: i64 = @intCast(self.w);
        const h_i: i64 = @intCast(self.h);
        const x0 = std.math.clamp(@as(i64, @intFromFloat(@floor(cx0))), 0, w_i);
        const y0 = std.math.clamp(@as(i64, @intFromFloat(@floor(cy0))), 0, h_i);
        const x1 = std.math.clamp(@as(i64, @intFromFloat(@ceil(cx1))), 0, w_i);
        const y1 = std.math.clamp(@as(i64, @intFromFloat(@ceil(cy1))), 0, h_i);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    pub fn fillRect(self: *Self, rect: elmz.Rect, fill: elmz.Fill) void {
        self.fillRectClip(rect, fill, elmz.Rect.unbounded);
    }

    pub fn fillRectClip(self: *Self, rect: elmz.Rect, fill: elmz.Fill, clip: elmz.Rect) void {
        const sp = self.clipSpan(rect, clip) orelse return;
        switch (fill) {
            // The solid case hoists the colour out of the loop entirely: this
            // is still the path every plain background takes, and it must not
            // pay for gradients existing.
            .solid => |c| {
                var y = sp.y0;
                while (y < sp.y1) : (y += 1) self.fillRow(sp.x0, sp.x1, @intCast(y), c);
            },

            // A linear ramp is AFFINE in x and y, so every geometric term in
            // the projection is constant for the whole fill. Deriving them
            // once -- including the reciprocal of the axis length -- is what
            // separates a 20x fill from a 1x one. The old path rebuilt the
            // axis, the length and the whole projection on every pixel.
            .linear => |g| {
                const ax = rect.x + g.from[0] * rect.w;
                const ay = rect.y + g.from[1] * rect.h;
                const dx = (rect.x + g.to[0] * rect.w) - ax;
                const dy = (rect.y + g.to[1] * rect.h) - ay;
                const len2 = dx * dx + dy * dy;
                if (!(len2 > 0)) {
                    const c = g.stops.at(0);
                    var y = sp.y0;
                    while (y < sp.y1) : (y += 1) self.fillRow(sp.x0, sp.x1, @intCast(y), c);
                    return;
                }
                const inv = 1.0 / len2;
                const step = dx * inv; // dt per pixel along x
                const xm = @as(f32, @floatFromInt(sp.x0)) + 0.5;
                var y = sp.y0;
                if (dy == 0) {
                    // Horizontal: the colour depends on x ONLY, so the row of
                    // colours is the same on every scanline. Build it once per
                    // band of columns and replay it -- the ramp becomes a row
                    // fill, which is what makes it cost the same as a solid.
                    const band: i64 = 512;
                    var xs = sp.x0;
                    while (xs < sp.x1) {
                        const xe = @min(sp.x1, xs + band);
                        const n: usize = @intCast(xe - xs);
                        var lut: [512]elmz.Color = undefined;
                        var tt = ((@as(f32, @floatFromInt(xs)) + 0.5 - ax) * dx) * inv;
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            lut[i] = g.stops.atFast(tt);
                            tt += step;
                        }
                        var yy = sp.y0;
                        while (yy < sp.y1) : (yy += 1) {
                            const row = (@as(usize, @intCast(yy)) * self.w + @as(usize, @intCast(xs))) * 4;
                            var j: usize = 0;
                            var off = row;
                            while (j < n) : (j += 1) {
                                const c = lut[j];
                                if (c.a == 255) {
                                    self.px[off + 0] = c.r;
                                    self.px[off + 1] = c.g;
                                    self.px[off + 2] = c.b;
                                } else {
                                    self.blendPixel(xs + @as(i64, @intCast(j)), yy, c);
                                }
                                off += 4;
                            }
                        }
                        xs = xe;
                    }
                    return;
                }
                if (dx == 0) {
                    // Constant along the scanline, so it is sampled once per
                    // ROW and the row fill does the rest. This is the case that
                    // made vertical gradients free and horizontal ones 20x.
                    while (y < sp.y1) : (y += 1) {
                        const ym = @as(f32, @floatFromInt(y)) + 0.5;
                        const t = ((xm - ax) * dx + (ym - ay) * dy) * inv;
                        self.fillRow(sp.x0, sp.x1, @intCast(y), g.stops.atFast(t));
                    }
                    return;
                }
                while (y < sp.y1) : (y += 1) {
                    const ym = @as(f32, @floatFromInt(y)) + 0.5;
                    // No multiply and no divide inside the row: `t` advances
                    // by a constant. Error over a scanline is under 1e-5,
                    // which is three orders below one unit of 8-bit colour.
                    var t = ((xm - ax) * dx + (ym - ay) * dy) * inv;
                    const row = @as(usize, @intCast(y)) * self.w;
                    var x = sp.x0;
                    var off = (row + @as(usize, @intCast(sp.x0))) * 4;
                    while (x < sp.x1) : (x += 1) {
                        const c = g.stops.atFast(t);
                        if (c.a == 255) {
                            self.px[off + 0] = c.r;
                            self.px[off + 1] = c.g;
                            self.px[off + 2] = c.b;
                        } else {
                            self.blendPixel(x, y, c);
                        }
                        off += 4;
                        t += step;
                    }
                }
            },

            .radial => |g| {
                const cx = rect.x + g.center[0] * rect.w;
                const cy = rect.y + g.center[1] * rect.h;
                const r = g.radius * rect.w;
                var y = sp.y0;
                if (!(r > 0)) {
                    const c = g.stops.at(1);
                    while (y < sp.y1) : (y += 1) self.fillRow(sp.x0, sp.x1, @intCast(y), c);
                    return;
                }
                // Still a square root per pixel -- that is what a radial ramp
                // is -- but the centre and the reciprocal of the radius are
                // fixed, so only the distance changes.
                const inv = 1.0 / r;
                while (y < sp.y1) : (y += 1) {
                    const dyv = (@as(f32, @floatFromInt(y)) + 0.5) - cy;
                    const row = @as(usize, @intCast(y)) * self.w;
                    var x = sp.x0;
                    var off = (row + @as(usize, @intCast(sp.x0))) * 4;
                    while (x < sp.x1) : (x += 1) {
                        const dxv = (@as(f32, @floatFromInt(x)) + 0.5) - cx;
                        const c = g.stops.atFast(@sqrt(dxv * dxv + dyv * dyv) * inv);
                        if (c.a == 255) {
                            self.px[off + 0] = c.r;
                            self.px[off + 1] = c.g;
                            self.px[off + 2] = c.b;
                        } else {
                            self.blendPixel(x, y, c);
                        }
                        off += 4;
                    }
                }
            },
        }
    }

    fn scaleFor(size: f32) i64 {
        const s = @round(size / 7.0);
        return if (s < 1) 1 else @intFromFloat(s);
    }

    /// TrueType text, drawn by the same font that measured it.
    pub fn drawText(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8) void {
        self.drawTextClip(x, y, size, fill, bytes, elmz.Rect.unbounded);
    }

    pub fn drawTextClip(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        ttf.drawText(self.px, self.w, self.h, x, y, size, fill, bytes, clip);
    }

    /// The original 5x7 bitmap renderer, kept for tests and as the "no font"
    /// fallback path.
    pub fn drawTextBitmap(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8) void {
        const s = scaleFor(size);
        const bm = measureTextBitmap(bytes, size);
        const box: elmz.Rect = .{ .x = x, .y = y, .w = bm.width, .h = bm.height };
        const solid_c: ?elmz.Color = switch (fill) {
            .solid => |cc| cc,
            else => null,
        };
        var cursor: i64 = @intFromFloat(@floor(x));
        const top: i64 = @intFromFloat(@floor(y));
        for (bytes) |ch| {
            const rows = glyph(ch);
            for (rows, 0..) |row, ry| {
                const bits: u32 = row;
                var col: u5 = 0;
                while (col < 5) : (col += 1) {
                    const shift: u5 = 4 - col;
                    if ((bits >> shift) & 1 == 0) continue;
                    var dy: i64 = 0;
                    while (dy < s) : (dy += 1) {
                        var dx: i64 = 0;
                        while (dx < s) : (dx += 1) {
                            const px_x = cursor + @as(i64, col) * s + dx;
                            const px_y = top + @as(i64, @intCast(ry)) * s + dy;
                            self.blendPixel(px_x, px_y, solid_c orelse fill.colorAt(
                                box,
                                @as(f32, @floatFromInt(px_x)) + 0.5,
                                @as(f32, @floatFromInt(px_y)) + 0.5,
                            ));
                        }
                    }
                }
            }
            cursor += 6 * s;
        }
    }

    fn blendCoverage(self: *Self, x: i64, y: i64, color: elmz.Color, cov: f32) void {
        const a = cov * (@as(f32, @floatFromInt(color.a)) / 255.0);
        if (a <= 0) return;
        const i = (@as(usize, @intCast(y)) * self.w + @as(u32, @intCast(x))) * 4;
        const inv = 1.0 - a;
        self.px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * a + @as(f32, @floatFromInt(self.px[i + 0])) * inv);
        self.px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * a + @as(f32, @floatFromInt(self.px[i + 1])) * inv);
        self.px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * a + @as(f32, @floatFromInt(self.px[i + 2])) * inv);
    }

    /// Rounded rect by signed distance: the coverage of a pixel is derived
    /// from its distance to the rounded outline, which antialiases the curve
    /// and, with `stroke`, gives a 1px outline that follows it for free.
    pub fn roundRect(self: *Self, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool) void {
        self.roundRectClip(rect, radius, fill, stroke, elmz.Rect.unbounded);
    }

    pub fn roundRectClip(self: *Self, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool, clip: elmz.Rect) void {
        // The corner geometry comes from the unclipped rect on purpose: a clip
        // is a window over the shape, never a change to the shape.
        const r = @min(radius, @min(rect.w, rect.h) * 0.5);
        if (r <= 0) {
            if (!stroke) return self.fillRectClip(rect, fill, clip);
            // A solid square outline really is four quads, and emit draws it
            // that way. A GRADIENT one cannot be: each quad's box is 1px on
            // its short axis, so the ramp would restart per edge. Those fall
            // through to the SDF below with r = 0, which is a box.
            if (fill.isSolid()) return;
        }
        const hx = rect.w * 0.5 - r;
        const hy = rect.h * 0.5 - r;
        const cx = rect.x + rect.w * 0.5;
        const cy = rect.y + rect.h * 0.5;

        const sp = self.clipSpan(rect, clip) orelse return;

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                var cov = std.math.clamp(0.5 - d, 0, 1);
                if (stroke) cov -= std.math.clamp(0.5 - (d + 1.0), 0, 1);
                if (cov > 0) self.blendCoverage(x, y, fill.colorAt(
                    rect,
                    @as(f32, @floatFromInt(x)) + 0.5,
                    @as(f32, @floatFromInt(y)) + 0.5,
                ), cov);
            }
        }
    }

    /// A glow or shadow: the same signed distance the rounded rect is built
    /// from, with the coverage term swapped for a falloff that straddles the
    /// edge -- solid `blur / 2` inside it, gone `blur / 2` outside.
    ///
    /// Only the ring is walked. The interior is fully opaque by construction
    /// and the element paints over it, so looping over it would be work whose
    /// result is never seen. That keeps a glow's cost proportional to its
    /// circumference rather than to the area it wraps.
    pub fn halo(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        if (h.color.a == 0) return;
        // Explicit beats the default. A quality setting the library can
        // second-guess is not an escape hatch, so `.sdf` is honoured even where
        // a stencil would be cheaper.
        //
        // Two paths, no policy: `baked` is the default value and the fast one,
        // and there is no size threshold left to second-guess it. A heuristic
        // that "improves" the default is the thing that made a low-blur halo
        // slow for a year, so the choice is the caller's or nobody's.
        // The old rule sent blur < 10 to the distance field on the argument
        // that "the ramp has few pixels left to cache, and baking would cost
        // more than it saves". That was reasoning about a mask the size of the
        // shape. Slicing made a bake independent of area, and the benchmark
        // then inverted it at every blur measured, cold as well as hot:
        //
        //     blur    sdf hot   baked cold   baked hot
        //        4      68.5us       45.7us       39.0us
        //       24     152.6us      108.8us       88.2us
        //       40     219.5us      147.4us      106.2us
        //
        // The one case left that could favour the field is cache pressure, so
        // it was measured too: 16 distinct silhouettes redrawn every frame
        // (past the 8-entry cache, so LRU misses on every halo) still costs
        // 0.915ms baked against 1.202ms for the field. Nothing is left for a
        // heuristic to protect.
        // A stencil is keyed on the silhouette alone, so it cannot carry the cut
        // that turns an offset or grown rim into a shadow: the element's own
        // outline is not in the key. Those cases take the field.
        const geometric_cut = h.mode == .outer_glow and (h.offset[0] != 0 or h.offset[1] != 0 or h.spread != 0);
        const use_sdf = h.light != null or geometric_cut or switch (h.quality) {
            .sdf => true,
            .baked => false,
        };
        // The blended metric depends on the shape's own aspect, and a stencil is
        // keyed on (radius, blur, corner) with no width or height in the key: a
        // template baked from one silhouette and stretched across another would
        // carry the wrong ellipse. Cheap to give up -- this is the mode that is
        // already the widest band, and a wide band is where a bake saved least.
        if (h.mode == .inner_glow) {
            const sp2: f32 = -h.spread;
            const bl = @max(h.blur, 0);
            if (circularity(rect.w + sp2 * 2, rect.h + sp2 * 2, bl) > 0)
                return self.haloSdf(rect, corner, h, clip);
        }
        if (use_sdf) return self.haloSdf(rect, corner, h, clip);
        self.haloBaked(rect, corner, h, clip);
    }

    fn haloSdf(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const blur = @max(h.blur, 0);
        // The silhouette the ramp runs away from, after spread and offset.
        // An inner glow never moves its silhouette. Shrinking it for `spread`
        // (the first attempt) put the bright band three pixels inside the face, so
        // the rim floated off the edge it is supposed to light and the button read
        // as a stripe across the middle. Growing it instead throws light outside
        // the element. So the shape stays the element and `spread` becomes what it
        // says -- a flat core -- by holding the ramp at full brightness for that
        // many pixels before it begins to decay.
        const spread = if (h.mode == .inner_glow) 0 else h.spread;
        const shape = elmz.Rect{
            .x = rect.x + h.offset[0] - spread,
            .y = rect.y + h.offset[1] - spread,
            .w = rect.w + spread * 2,
            .h = rect.h + spread * 2,
        };
        if (shape.w <= 0 or shape.h <= 0) return;
        const r = @min(@max(corner + spread, 0), @min(shape.w, shape.h) * 0.5);
        const hx = shape.w * 0.5 - r;
        const hy = shape.h * 0.5 - r;
        const cx = shape.x + shape.w * 0.5;
        const cy = shape.y + shape.h * 0.5;

        // The element's own outline, before spread and offset: an outer rim is cut
        // against THIS, so a displaced shadow still fills the strip between the
        // element and its silhouette instead of leaving a gap there.
        const er = @min(@max(corner, 0), @min(rect.w, rect.h) * 0.5);
        const ehx = rect.w * 0.5 - er;
        const ehy = rect.h * 0.5 - er;
        const ecx = rect.x + rect.w * 0.5;
        const ecy = rect.y + rect.h * 0.5;

        // The direction the shadow is thrown. A light at clock `deg` sits on that
        // side and travels toward the shape, so the cast points the opposite way:
        // at 0 the lamp is overhead and the cast points to +y.
        var cast: [2]f32 = .{ 0, 0 };
        if (h.light) |deg| {
            const a = deg * std.math.pi / 180.0;
            cast = .{ -@sin(a), @cos(a) };
        }

        // Ring bounds: the shape grown by the falloff, plus one pixel for the
        // antialiased edge itself. A lit ramp reaches further on the cast side.
        const grow: f32 = falloffReach(h.mode, blur, h.light != null) + 1;
        const ring = elmz.Rect{
            .x = shape.x - grow,
            .y = shape.y - grow,
            .w = shape.w + grow * 2,
            .h = shape.h + grow * 2,
        };
        // A rim light keeps the shape where it MEETS it and loses it as it decays
        // inward. That is the whole of `circularity`'s gate: zero for a narrow rim,
        // which is tracing the outline and should keep the corners it is attached
        // to, rising as the falloff becomes a real fraction of the shape.
        //
        // Only inner glows blend. An outward ramp already rounds itself off without
        // help: growing `blur/2` on every side takes an 80x60 box from 1.27 aspect
        // to 1.14 and the corner radius grows with it, so its tail is round already.
        const circular: f32 = if (h.mode == .inner_glow) circularity(shape.w, shape.h, blur) else 0;
        const ea = shape.w * 0.5;
        const eb = shape.h * 0.5;
        // Depth is measured against the reach actually available, not against
        // `blur` alone: on a face shorter than the falloff the ramp never gets to
        // run its full length, and normalising by `blur` there would leave the
        // blend at a fraction of where it needs to be. `min` of the two means the
        // tail is fully pooled by the time the glow reaches the middle, whichever
        // is smaller.
        const reach = @min(blur, @min(ea, eb));

        const sp = self.clipSpan(ring, clip) orelse return;

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                // Nothing to draw once the ramp has run out, and nothing to
                // draw deep inside: the shape is opaque there.
                // Cutting an outer rim against the element is a silhouette, so it
                // has to be feathered like one. A binary inside/outside test steps
                // a whole pixel; the fill underneath was antialiased against the
                // background and the rim is bright, so that single step is the
                // rough edge. `cut` is the element's own coverage inverted: the rim
                // keeps whatever the fill did not cover.
                var cut: f32 = 1;
                if (h.mode == .outer_glow) {
                    const ex = @abs(@as(f32, @floatFromInt(x)) + 0.5 - ecx) - ehx;
                    const ey = @abs(@as(f32, @floatFromInt(y)) + 0.5 - ecy) - ehy;
                    const de = @sqrt(@max(ex, 0) * @max(ex, 0) + @max(ey, 0) * @max(ey, 0)) + @min(@max(ex, ey), 0) - er;
                    if (de < -1) continue;
                    cut = std.math.clamp(0.5 + de, 0, 1);
                }
                // Depth-gated blend: at the boundary the metric IS the shape's, so
                // the rim sits on the corners it belongs to; by the far end of the
                // falloff it has become the inscribed ellipse, which has none.
                var rd = d;
                if (circular > 0) {
                    const t = std.math.clamp(-d / reach, 0, 1) * circular;
                    rd = d + (ellipseDistance(px, py, ea, eb) - d) * t;
                }
                const w = if (h.light != null) lightWidth(blur, px, py, hx, hy, cast) else blur;
                // A flat core is a depth offset, not a bigger shape: the rim still
                // starts on the element edge, it just stays at full brightness for
                // `spread` before it starts to decay.
                const core: f32 = if (h.mode == .inner_glow) h.spread else 0;
                var cov = ramp(h.mode, rd, w, core);
                if (cov > 0) {
                    cov *= switch (h.mode) {
                        // Not feathered. The face's own fill already antialiases
                        // this boundary, and the rim underneath it is SOFT there
                        // (zero slope at the edge, see `ramp`), so multiplying by
                        // the boundary coverage as well just halves the rim's last
                        // pixel and leaves a seam where the two disagree.
                        .inner_glow => 1,
                        .glow => 1,
                        .outer_glow => cut,
                    };
                }
                if (cov > 0) self.blendCoverage(x, y, h.color, cov);
            }
        }
    }

    /// Blur the destination under `rect`, in place, then blend the result back
    /// through the rounded-rect coverage so a frosted card keeps its corners.
    ///
    /// Reads AND writes the canvas, which is the whole reason a frost is recorded
    /// before the element's own fill: what it frosts is what is underneath.
    ///
    /// Sampling clamps at the region's own edge rather than reaching outside it.
    /// That is what stops a frosted panel dragging black in from beyond its
    /// bounds, and it is why the region is the element's FULL rect, not its inset
    /// content box: the outermost row is then a little less blurred than the
    /// middle, the same trade CSS backdrop filters make.
    pub fn frost(self: *Self, rect: elmz.Rect, radius: f32, blur: f32, clip: elmz.Rect) void {
        if (blur <= 0) return;
        const region = rect.intersect(clip);
        if (region.isEmpty()) return;
        const sp = self.clipSpan(region, clip) orelse return;
        const w: usize = @intCast(sp.x1 - sp.x0);
        const h: usize = @intCast(sp.y1 - sp.y0);
        if (w == 0 or h == 0) return;

        const buf = self.gpa.alloc(u8, w * h * 4) catch return;
        defer self.gpa.free(buf);
        const scratch = self.gpa.alloc(u8, @max(w, h) * 4) catch return;
        defer self.gpa.free(scratch);

        // Span bounds are i64 because a clip can reach outside the canvas; the
        // region itself is already intersected, so the cast is a narrowing to a
        // value that provably fits.
        const x0: usize = @intCast(sp.x0);
        const y0: usize = @intCast(sp.y0);

        // Copy out first: a blur reads neighbours and cannot run in place.
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const di = ((y0 + y) * self.w + x0) * 4;
            @memcpy(buf[y * w * 4 ..][0 .. w * 4], self.px[di..][0 .. w * 4]);
        }

        // Three box passes on alternating axes: close enough to a Gaussian that
        // the difference is invisible at these radii, and O(pixels) instead of
        // O(pixels * radius).
        const rad: usize = @intFromFloat(@max(@round(blur * 0.5), 1));
        boxBlur(buf, w, h, rad, true, scratch);
        boxBlur(buf, w, h, rad, false, scratch);
        boxBlur(buf, w, h, rad, true, scratch);

        // Blend back through the shape's own coverage: 1 replaces the pixel with
        // the blurred one, 0 leaves it, and the antialiased edge and rounded
        // corners fall out of the same distance field the fill uses.
        const r = @min(@max(radius, 0), @min(rect.w, rect.h) * 0.5);
        const hx = rect.w * 0.5 - r;
        const hy = rect.h * 0.5 - r;
        const cx = rect.x + rect.w * 0.5;
        const cy = rect.y + rect.h * 0.5;
        y = 0;
        while (y < h) : (y += 1) {
            const py = @as(f32, @floatFromInt(y0 + y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const px = @as(f32, @floatFromInt(x0 + x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                const cov = std.math.clamp(0.5 - d, 0, 1);
                if (cov <= 0) continue;
                const o = (y * w + x) * 4;
                // The blurred RGB, composited with `cov` as its alpha. The
                // buffer's own alpha is ignored: a frost over a transparent
                // backdrop has no colour to show, which is one reason it pairs
                // with a translucent fill rather than replacing one.
                self.blendPixel(@intCast(x0 + x), @intCast(y0 + y), .{
                    .r = buf[o],
                    .g = buf[o + 1],
                    .b = buf[o + 2],
                    .a = @intFromFloat(cov * 255 + 0.5),
                });
            }
        }
    }

    /// Replay a recorded frame onto the pixels. `Runtime.frame` only records
    /// primitives; nothing is rasterised until this runs.
    pub fn paintFrame(self: *Self, prims: []const elmz.Primitive) void {
        const r = self.renderer();
        for (prims) |p| switch (p) {
            .quad => |q| r.quad(q.rect, q.fill, q.clip),
            .halo => |q| r.halo(q.rect, q.corner, q.halo, q.clip),
            .frost => |q| r.frost(q.rect, q.radius, q.blur, q.clip),
            .rrect => |q| r.roundedRect(q.rect, q.radius, q.fill, q.stroke, q.clip),
            .text => |t| r.text(t.x, t.y, t.size, t.fill, t.bytes, t.clip),
        };
    }

    /// Copy `src` into this canvas with its top-left at `at`, compositing by
    /// `src`'s alpha.
    ///
    /// The 4-byte RGBA stride is this file's business, so callers should never
    /// restate it -- that is how the two previous hand-written copies of this
    /// loop ended up in example `main`s. Anything that would land outside the
    /// destination is dropped rather than erroring: compositing a contact sheet
    /// is the use, and a half-visible tile is more useful than a fatal error.
    ///
    /// This was a `@memcpy` until a transparent source was needed, which is the
    /// one thing a straight copy cannot do: it writes the source's alpha over
    /// the destination's instead of blending into it. A fully opaque source row
    /// still takes the memcpy path, so the common case -- tiles, snapshots --
    /// stays byte-identical to the canvas it came from and pays nothing.
    pub fn blitFrom(self: *Self, src: *const Self, at: [2]u32) void {
        if (at[0] >= self.w or at[1] >= self.h) return;
        const copy_w: usize = @min(src.w, self.w - at[0]);
        const copy_h: usize = @min(src.h, self.h - at[1]);
        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            // usize throughout: w*h*4 overflows u32 on any canvas worth blitting.
            const dst_i = ((@as(usize, at[1]) + y) * self.w + at[0]) * 4;
            const src_i = (y * src.w) * 4;
            const drow = self.px[dst_i..][0 .. copy_w * 4];
            const srow = src.px[src_i..][0 .. copy_w * 4];
            if (rowOpaque(srow)) {
                @memcpy(drow, srow);
                continue;
            }
            var x: usize = 0;
            while (x < copy_w) : (x += 1) {
                const o = x * 4;
                if (srow[o + 3] == 0) continue; // invisible: leave the destination alone
                composite(drow[o..][0..4], srow[o..][0..4]);
            }
        }
    }

    /// Baked path: same ramp, sampled from a stencil instead of computed.
    ///
    /// The stencil is built in the shape's own space, so `offset` moves the
    /// blit and never the bake. A silhouette that would need an absurd mask
    /// falls back to the distance field rather than allocating it.
    fn haloBaked(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const blur = @max(h.blur, 0);
        // Insets for an inner glow; see `haloSdf`.
        const spread = if (h.mode == .inner_glow) 0 else h.spread;
        const shape = elmz.Rect{
            .x = rect.x + h.offset[0] - spread,
            .y = rect.y + h.offset[1] - spread,
            .w = rect.w + spread * 2,
            .h = rect.h + spread * 2,
        };
        if (shape.w <= 0 or shape.h <= 0) return;
        const r = @min(@max(corner + spread, 0), @min(shape.w, shape.h) * 0.5);
        const swi: i32 = @intFromFloat(@round(shape.w));
        const shi: i32 = @intFromFloat(@round(shape.h));
        // A stencil is keyed on the silhouette and has nowhere to record a flat
        // core, so an inner rim with any spread takes the field path.
        if (h.mode == .inner_glow and h.spread != 0) return self.haloSdf(rect, corner, h, clip);
        const m = self.maskFor(swi, shi, r, blur, h.mode) orelse return self.haloSdf(rect, corner, h, clip);

        const grow = falloffReach(h.mode, blur, false) + 1;
        // A template describes any size, so the target ring is computed here;
        // a whole stencil already knows how big it is.
        const rw: u32 = if (m.sw == 0)
            @intFromFloat(@ceil(@as(f32, @floatFromInt(swi)) + grow * 2))
        else
            m.rw;
        const rh: u32 = if (m.sw == 0)
            @intFromFloat(@ceil(@as(f32, @floatFromInt(shi)) + grow * 2))
        else
            m.rh;

        const ox: i64 = @intFromFloat(@round(shape.x - grow));
        const oy: i64 = @intFromFloat(@round(shape.y - grow));
        const ring = elmz.Rect{
            .x = @floatFromInt(ox),
            .y = @floatFromInt(oy),
            .w = @floatFromInt(rw),
            .h = @floatFromInt(rh),
        };
        const sp = self.clipSpan(ring, clip) orelse return;

        const sliced = m.sw == 0;
        const c = m.corner;
        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const j = y - oy;
            if (j < 0 or j >= rh) continue;
            const uj: u32 = @intCast(j);
            // Rows inside the corner band are copied; the band between them is
            // one stretched row, which is the middle row of the template.
            const sj: u32 = if (!sliced)
                uj
            else if (uj < c)
                uj
            else if (uj >= rh - c)
                m.rh - 1 - (rh - 1 - uj)
            else
                c;
            const row = m.px[@as(usize, sj) * m.rw ..][0..m.rw];
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const i = x - ox;
                if (i < 0 or i >= rw) continue;
                const ui: u32 = @intCast(i);
                const si: u32 = if (!sliced)
                    ui
                else if (ui < c)
                    ui
                else if (ui >= rw - c)
                    m.rw - 1 - (rw - 1 - ui)
                else
                    c;
                const a = row[si];
                if (a == 0) continue;
                self.blendCoverage(x, y, h.color, @as(f32, @floatFromInt(a)) / 255.0);
            }
        }
    }

    /// The stencil for one silhouette, built on first use and kept.
    ///
    /// Large silhouettes get a 9-SLICE TEMPLATE instead of a full mask. The
    /// coverage at the middle of an edge depends only on the distance from
    /// that edge, and the interior is solid, so one small square describes
    /// every size at a given radius and blur. `w` and `h` therefore drop out of
    /// the key -- which is the real prize: a view full of differently-sized
    /// glowing rows used to evict every mask every frame and bake forever.
    /// Memory is the side effect, not the point.
    ///
    /// Silhouettes too small to slice still get a full bake, so the cache holds
    /// two shapes of entry.
    fn maskFor(self: *Self, sw: i32, sh: i32, r: f32, blur: f32, mode: elmz.Halo.Mode) ?*Mask {
        if (sw <= 0 or sh <= 0) return null;
        const grow = falloffReach(mode, blur, false) + 1;
        const corner: u32 = @intFromFloat(@ceil(grow + r) + 1);

        // The template's centre column is the value `corner` pixels in, and the
        // blit stretches it across the whole interior. That is only sound where
        // the interior is SATURATED -- true for a glow and for a shadow, whose
        // ramp is fully opaque well inside the edge. An `.inner_glow` ramps the
        // other way and is fully TRANSPARENT in the interior, so `corner` lands
        // mid-ramp and stretching it pins the inside to a constant ~0.32: the
        // rim stops falling off and the middle of the shape never goes empty.
        // Inner glows are therefore never sliced.
        const sliceable = mode != .inner_glow and sw >= @as(i32, @intCast(corner * 2)) and sh >= @as(i32, @intCast(corner * 2));
        if (sliceable) {
            for (self.masks.items) |*m| {
                if (m.sw == 0 and m.r == r and m.blur == blur and m.corner == corner and m.mode == mode) return m;
            }
            // The template is a bake of a shape exactly large enough that its
            // two corner bands meet and the middle is the solid interior.
            const tsw: i32 = @intCast(corner * 2 + 1);
            const rw: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(tsw)) + grow * 2));
            if (@as(u64, rw) * @as(u64, rw) > 4_000_000) return null;
            const px = self.gpa.alloc(u8, @as(usize, rw) * rw) catch return null;
            bakeStencil(px, rw, rw, tsw, tsw, r, blur, grow, mode);
            self.bakes += 1;
            return self.admit(px, .{ .sw = 0, .sh = 0, .r = r, .blur = blur, .mode = mode, .corner = corner, .rw = rw, .rh = rw });
        }

        for (self.masks.items) |*m| {
            if (m.sw == sw and m.sh == sh and m.r == r and m.blur == blur and m.mode == mode) return m;
        }
        const rw: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(sw)) + grow * 2));
        const rh: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(sh)) + grow * 2));
        if (@as(u64, rw) * @as(u64, rh) > 4_000_000) return null;
        const px = self.gpa.alloc(u8, @as(usize, rw) * rh) catch return null;
        bakeStencil(px, rw, rh, sw, sh, r, blur, grow, mode);
        self.bakes += 1;
        return self.admit(px, .{ .sw = sw, .sh = sh, .r = r, .blur = blur, .mode = mode, .rw = rw, .rh = rh });
    }

    /// Install a baked stencil, evicting the eldest when the cache is full.
    fn admit(self: *Self, px: []u8, entry: Mask) ?*Mask {
        if (self.masks.items.len >= 8) {
            const old = self.masks.orderedRemove(0);
            self.gpa.free(old.px);
        }
        self.masks.append(self.gpa, .{
            .sw = entry.sw,
            .sh = entry.sh,
            .r = entry.r,
            .blur = entry.blur,
            .corner = entry.corner,
            .rw = entry.rw,
            .rh = entry.rh,
            .px = px,
        }) catch {
            self.gpa.free(px);
            return null;
        };
        return &self.masks.items[self.masks.items.len - 1];
    }

    /// Coverage of one rounded-rect silhouette grown by `grow` on every side,
    /// into a `rw` x `rh` buffer. The shape's own top-left lands at
    /// (grow, grow), which is what lets a template's corner band be copied
    /// straight out at any target size.
    fn bakeStencil(px: []u8, rw: u32, rh: u32, sw: i32, sh: i32, r: f32, blur: f32, grow: f32, mode: elmz.Halo.Mode) void {
        const hx = @as(f32, @floatFromInt(sw)) * 0.5 - r;
        const hy = @as(f32, @floatFromInt(sh)) * 0.5 - r;
        const cx = grow + @as(f32, @floatFromInt(sw)) * 0.5;
        const cy = grow + @as(f32, @floatFromInt(sh)) * 0.5;
        var j: u32 = 0;
        while (j < rh) : (j += 1) {
            const py = @as(f32, @floatFromInt(j)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var i: u32 = 0;
            while (i < rw) : (i += 1) {
                const pxx = @as(f32, @floatFromInt(i)) + 0.5 - cx;
                const qx = @abs(pxx) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                const cov = ramp(mode, d, blur, 0);
                px[@as(usize, j) * rw + i] = @intFromFloat(cov * 255.0 + 0.5);
            }
        }
    }

    /// True when every pixel in a row of RGBA bytes is fully opaque.
    fn rowOpaque(row: []const u8) bool {
        var i: usize = 3;
        while (i < row.len) : (i += 4) {
            if (row[i] != 255) return false;
        }
        return true;
    }

    /// Source-over one pixel, straight (non-premultiplied) alpha.
    ///
    /// Destination alpha is tracked rather than assumed opaque: a canvas made
    /// by `init` starts at alpha 0, and compositing onto one of those is the
    /// case that silently produced black before. With an opaque destination
    /// this reduces to `blendPixel`'s arithmetic, so a composited blit and a
    /// painted quad of the same colour land on the same byte.
    fn composite(dst: *[4]u8, src: *const [4]u8) void {
        const sa: f32 = @as(f32, @floatFromInt(src[3])) / 255.0;
        const da: f32 = @as(f32, @floatFromInt(dst[3])) / 255.0;
        const out_a: f32 = sa + da * (1 - sa);
        if (out_a <= 0) {
            dst.* = .{ 0, 0, 0, 0 };
            return;
        }
        const dst_w: f32 = da * (1 - sa);
        inline for (0..3) |ch| {
            const s: f32 = @floatFromInt(src[ch]);
            const d: f32 = @floatFromInt(dst[ch]);
            dst[ch] = toByte((s * sa + d * dst_w) / out_a);
        }
        dst[3] = toByte(out_a * 255.0);
    }

    /// `@intFromFloat` traps outside the type, and a rounding error one ulp
    /// above 255 would be a crash in the paint loop rather than a wrong pixel.
    fn toByte(v: f32) u8 {
        return @intFromFloat(@min(255.0, @max(0.0, v)));
    }

    /// Encode to PNG and write it to the working directory.
    ///
    /// Every example wants exactly this, and the two-line version is easy to
    /// get subtly wrong: `encodePng` returns owned bytes that must survive
    /// until after the write.
    pub fn writePng(self: *const Self, io: std.Io, gpa: Allocator, name: []const u8) !void {
        const png = try self.encodePng(gpa);
        defer gpa.free(png);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = png });
    }

    pub fn measureText(bytes: []const u8, size: f32) elmz.TextMetrics {
        return ttf.measure(bytes, size);
    }

    pub fn wrapText(bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
        return ttf.wrapLines(bytes, size, max_width, out);
    }

    pub fn measureTextBitmap(bytes: []const u8, size: f32) elmz.TextMetrics {
        const s = scaleFor(size);
        const n: i64 = @intCast(bytes.len);
        const h: f32 = @floatFromInt(7 * s);
        if (n == 0) return .{ .width = 0, .height = h, .ascent = h, .descent = 0, .line_height = h };
        return .{
            .width = @floatFromInt(n * 6 * s - s),
            .height = h,
            .ascent = h,
            .descent = 0,
            .line_height = h,
        };
    }

    // -- the elmz.Renderer vtable -------------------------------------------

    pub fn renderer(self: *Self) elmz.Renderer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = elmz.Renderer.VTable{
        .quad = vtQuad,
        .rrect = vtRrect,
        .text = vtText,
        .halo = vtHalo,
        .frost = vtFrost,
        .measure_text = vtMeasure,
        .wrap_text = vtWrap,
    };

    fn vtFrost(ptr: *anyopaque, rect: elmz.Rect, radius: f32, blur: f32, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.frost(rect, radius, blur, clip);
    }

    fn vtHalo(ptr: *anyopaque, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.halo(rect, corner, h, clip);
    }

    fn vtQuad(ptr: *anyopaque, rect: elmz.Rect, fill: elmz.Fill, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.fillRectClip(rect, fill, clip);
    }

    fn vtRrect(ptr: *anyopaque, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.roundRectClip(rect, radius, fill, stroke, clip);
    }

    fn vtText(ptr: *anyopaque, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.drawTextClip(x, y, size, fill, bytes, clip);
    }

    fn vtMeasure(ptr: *anyopaque, bytes: []const u8, size: f32) elmz.TextMetrics {
        _ = ptr;
        return measureText(bytes, size);
    }

    fn vtWrap(
        ptr: *anyopaque,
        bytes: []const u8,
        size: f32,
        max_width: f32,
        out: [][]const u8,
    ) usize {
        _ = ptr;
        return wrapText(bytes, size, max_width, out);
    }

    // -- PNG ----------------------------------------------------------------

    pub fn encodePng(self: *const Self, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const w = gpa;

        try out.appendSlice(w, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });

        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], self.w, .big);
        std.mem.writeInt(u32, ihdr[4..8], self.h, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // RGBA
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try writeChunk(w, &out, "IHDR", &ihdr);

        // raw scanlines with filter byte 0
        const stride: usize = @as(usize, self.w) * 4;
        var raw = try w.alloc(u8, (@as(usize, self.h)) * (stride + 1));
        defer w.free(raw);
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            const dst = @as(usize, y) * (stride + 1);
            raw[dst] = 0;
            @memcpy(raw[dst + 1 .. dst + 1 + stride], self.px[@as(usize, y) * stride ..][0..stride]);
        }

        const idat = try zlibStored(w, raw);
        defer w.free(idat);
        try writeChunk(w, &out, "IDAT", idat);
        try writeChunk(w, &out, "IEND", &.{});

        return out.toOwnedSlice(w);
    }

    fn writeChunk(gpa: Allocator, out: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, tag);
        try out.appendSlice(gpa, data);

        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(data);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
        try out.appendSlice(gpa, &crc_bytes);
    }

    /// zlib stream using stored (uncompressed) deflate blocks — no compressor
    /// dependency, valid PNG output.
    fn zlibStored(gpa: Allocator, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, &.{ 0x78, 0x01 });

        var off: usize = 0;
        while (true) {
            const chunk = @min(data.len - off, 65535);
            const is_final = off + chunk == data.len;
            try out.append(gpa, if (is_final) 0x01 else 0x00);
            var lens: [4]u8 = undefined;
            std.mem.writeInt(u16, lens[0..2], @intCast(chunk), .little);
            std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(chunk)), .little);
            try out.appendSlice(gpa, &lens);
            try out.appendSlice(gpa, data[off .. off + chunk]);
            off += chunk;
            if (is_final) break;
        }

        var adler_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &adler_bytes, std.hash.Adler32.hash(data), .big);
        try out.appendSlice(gpa, &adler_bytes);

        return out.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------------
// 5x7 font. MSB is the leftmost pixel.
// ---------------------------------------------------------------------------

fn glyph(ch: u8) [7]u5 {
    const c = std.ascii.toUpper(ch);
    return switch (c) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        '+' => .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        '=' => .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 },
        '.' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 },
        ':' => .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 },
        '%' => .{ 0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011 },
        '(' => .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
        ')' => .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
        '>' => .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 },
        '<' => .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 },
        ',' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00110, 0b00110, 0b00100 },
        '\'' => .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
        '_' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 },
        ';' => .{ 0b00000, 0b00110, 0b00110, 0b00000, 0b00110, 0b00110, 0b00100 },
        '?' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100 },
        '*' => .{ 0b00000, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0b00000 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

// ---------------------------------------------------------------------------
// the rasterizer, under test instead of under eyeball
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a quad covers exactly the pixels it names and nothing else" {
    var c = try Canvas.init(testing.allocator, 20, 20);
    defer c.deinit();

    c.fillRect(.{ .x = 5, .y = 5, .w = 10, .h = 10 }, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });

    var lit: usize = 0;
    for (0..20) |y| for (0..20) |x| {
        const i = (y * 20 + x) * 4;
        if (c.px[i] != 0) lit += 1;
    };
    try testing.expectEqual(@as(usize, 100), lit);
    // and it is the right 100: corners in, neighbours out
    const at = struct {
        fn f(px: []const u8, x: usize, y: usize) u8 {
            return px[(y * 20 + x) * 4];
        }
    }.f;
    try testing.expectEqual(@as(u8, 255), at(c.px, 5, 5));
    try testing.expectEqual(@as(u8, 255), at(c.px, 14, 14));
    try testing.expectEqual(@as(u8, 0), at(c.px, 4, 5));
    try testing.expectEqual(@as(u8, 0), at(c.px, 15, 14));
}

/// Decode a PNG this library wrote -- signature, chunks, IDAT, stored deflate
/// blocks -- and hand back the raw RGBA rows with the filter bytes stripped.
///
/// Deliberately not a general PNG decoder: it asserts the profile we EMIT, so a
/// change to the encoder has to come through here. The stored-block header is
/// checked against its own complement, which is the one part of the zlib stream
/// a writer can get wrong without the bytes changing.
fn decodeStoredPng(gpa: Allocator, png: []const u8) ![]u8 {
    var w: u32 = 0;
    var h: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var i: usize = 8; // signature
    while (i + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[i..][0..4], .big);
        const tag = png[i + 4 ..][0..4];
        const data = png[i + 8 ..][0..len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(gpa, data);
        }
        i += 12 + len;
    }
    if (w == 0 or h == 0) return error.MissingHeader;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var z: usize = 2; // zlib header
    while (true) {
        if (z + 5 > idat.items.len) return error.TruncatedDeflate;
        const final = (idat.items[z] & 1) == 1;
        const n = std.mem.readInt(u16, idat.items[z + 1 ..][0..2], .little);
        const inv = std.mem.readInt(u16, idat.items[z + 3 ..][0..2], .little);
        if (inv != ~n) return error.BadDeflateLength;
        try raw.appendSlice(gpa, idat.items[z + 5 ..][0..n]);
        z += 5 + n;
        if (final) break;
    }

    const cols: usize = w;
    const rows: usize = h;
    const px = try gpa.alloc(u8, cols * rows * 4);
    errdefer gpa.free(px);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const row = raw.items[y * (1 + cols * 4) ..][0..(1 + cols * 4)];
        if (row[0] != 0) return error.UnsupportedFilter; // we always write 0
        @memcpy(px[y * cols * 4 ..][0..(cols * 4)], row[1..]);
    }
    return px;
}

test "a quad larger than the canvas is clipped, not corrupting" {
    var c = try Canvas.init(testing.allocator, 8, 8);
    defer c.deinit();
    c.fillRect(.{ .x = -50, .y = -50, .w = 500, .h = 500 }, .{ .solid = .{ .r = 9, .g = 9, .b = 9, .a = 255 } });
    var i: usize = 0;
    while (i < c.px.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 9), c.px[i]);
        try testing.expectEqual(@as(u8, 9), c.px[i + 2]);
        // Alpha is NOT untouched: an opaque quad makes the canvas opaque. This
        // assertion used to read 0, which recorded the bug -- a frame painted
        // entirely with opaque colours exported as a fully transparent PNG.
        try testing.expectEqual(@as(u8, 255), c.px[i + 3]);
    }
}

test "text is really antialiased and its measure is not a guess" {
    var c = try Canvas.init(testing.allocator, 200, 40);
    defer c.deinit();
    c.drawText(2, 2, 20, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } }, "Hamburgefonstiv");

    var seen = std.AutoHashMap(u8, void).init(testing.allocator);
    defer seen.deinit();
    for (c.px) |b| try seen.put(b, {});

    // A bitmap font at integer scale yields 2 levels (0 and ink). Coverage
    // rasterisation yields a spread; if this drops to 2, the TTF path is dead.
    try testing.expect(seen.count() > 20);

    const m = Canvas.measureText("Hamburgefonstiv", 20);
    try testing.expect(m.width > 100 and m.width < 200);
    try testing.expect(m.height >= 20);
}

test "utf-8 is decoded, not measured as bytes" {
    const one = Canvas.measureText("日", 24);
    const three = Canvas.measureText("日本語", 24);
    try testing.expect(one.width > 8);
    // three copies of one glyph == one glyph measured three times
    try testing.expectApproxEqAbs(one.width * 3, three.width, 0.01);
    // and nothing like the 9 bytes it occupies
    try testing.expect(@abs(three.width - one.width * 9) > 1);
    // accented latin too: 'é' is two bytes, one glyph
    try testing.expectApproxEqAbs(
        Canvas.measureText("e", 20).width,
        Canvas.measureText("é", 20).width,
        0.01,
    );
}

test "wrapping breaks at spaces and loses nothing" {
    var buf: [8][]const u8 = undefined;
    const text = "the quick brown fox jumps";
    const n = Canvas.wrapText(text, 14, 60, &buf);
    try testing.expect(n >= 2);

    var joined: [64]u8 = undefined;
    var len: usize = 0;
    for (buf[0..n]) |line| {
        try testing.expect(Canvas.measureText(line, 14).width <= 60.5);
        if (len > 0) {
            joined[len] = ' ';
            len += 1;
        }
        @memcpy(joined[len..][0..line.len], line);
        len += line.len;
    }
    try testing.expectEqualStrings(text, joined[0..len]);
}

test "a single overlong word makes progress instead of looping" {
    var buf: [4][]const u8 = undefined;
    const n = Canvas.wrapText("antidisestablishmentarianism", 14, 40, &buf);
    try testing.expect(n >= 1 and n <= 4);
}

test "a wider budget produces fewer lines" {
    var a: [16][]const u8 = undefined;
    var b: [16][]const u8 = undefined;
    const text = "alpha beta gamma delta epsilon zeta";
    const narrow = Canvas.wrapText(text, 12, 50, &a);
    const wide = Canvas.wrapText(text, 12, 300, &b);
    try testing.expect(narrow > wide);
    try testing.expectEqual(@as(usize, 1), wide);
}

test "line height accounts for the font's line gap" {
    const m = Canvas.measureText("Ag", 20);
    // DejaVu declares a zero line gap, so spacing == height here. The field
    // exists because that is a property of the font, not a constant.
    try testing.expect(m.line_height >= m.height);
    try testing.expect(m.ascent > 0);
    try testing.expect(m.descent < 0);
}

// ---------------------------------------------------------------------------
// gradients: the numbers, not the vibes
// ---------------------------------------------------------------------------

fn chanAt(px: []const u8, w: u32, x: usize, y: usize) u8 {
    return px[(y * @as(usize, w) + x) * 4];
}

test "a vertical gradient ramps top to bottom and is constant across each row" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 40, 100);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 }); // green: anything unpainted shows up
    c.fillRect(.{ .x = 0, .y = 0, .w = 40, .h = 100 }, elmz.Fill.vgrad(
        elmz.Color.rgbHex(0x000000),
        elmz.Color.rgbHex(0xffffff),
    ));
    try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 0))), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 50))), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 99))), 3);
    // the per-row fast path is only correct if the colour really is row-constant
    try std.testing.expectEqual(chanAt(c.px, c.w, 1, 50), chanAt(c.px, c.w, 38, 50));
}

test "a horizontal gradient varies by column and not by row" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 100, 10);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 });
    c.fillRect(.{ .x = 0, .y = 0, .w = 100, .h = 10 }, elmz.Fill.hgrad(
        elmz.Color.rgbHex(0x000000),
        elmz.Color.rgbHex(0xffffff),
    ));
    try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(chanAt(c.px, c.w, 0, 5))), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(chanAt(c.px, c.w, 50, 5))), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(chanAt(c.px, c.w, 99, 5))), 3);
    try std.testing.expectEqual(chanAt(c.px, c.w, 50, 1), chanAt(c.px, c.w, 50, 8));
}

test "a radial fill is brightest at the centre and falls off outward" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 80, 80);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 });
    c.fillRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 }, elmz.Fill.radialFill(
        elmz.Color.rgbHex(0xffffff),
        elmz.Color.rgbHex(0x000000),
    ));
    const centre = chanAt(c.px, c.w, 40, 40);
    const edge = chanAt(c.px, c.w, 0, 0);
    try std.testing.expect(centre > 200);
    try std.testing.expect(edge < 60);
}

test "a gradient BORDER ramps around the outline and leaves the interior alone" {
    const gpa = std.testing.allocator;
    const bg = elmz.Color.rgbHex(0x102030);
    for ([_]f32{ 0, 14 }) |radius| {
        var c = try Canvas.init(gpa, 60, 60);
        defer c.deinit();
        c.clear(bg);
        c.roundRectClip(.{ .x = 10, .y = 10, .w = 40, .h = 40 }, radius, elmz.Fill.vgrad(
            elmz.Color.rgbHex(0xff0000),
            elmz.Color.rgbHex(0x0000ff),
        ), true, elmz.Rect.unbounded);
        // top edge is the ramp's start, bottom edge its end
        const top = c.px[((10 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        const bot = c.px[((49 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        try std.testing.expect(top[0] > 150 and top[2] < 100);
        try std.testing.expect(bot[2] > 150 and bot[0] < 100);
        // interior untouched: a stroke must not fill the shape
        const mid = c.px[((30 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        try std.testing.expectEqual(bg.r, mid[0]);
        try std.testing.expectEqual(bg.g, mid[1]);
        try std.testing.expectEqual(bg.b, mid[2]);
    }
}

test "text takes a gradient fill, not just a solid colour" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 240, 48);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 0, .b = 0 });
    c.drawText(2, 2, 30, elmz.Fill.hgrad(
        elmz.Color.rgbHex(0xff0000),
        elmz.Color.rgbHex(0x0000ff),
    ), "MMMMMMMM");

    // Inked span, so the test follows the glyphs instead of assuming where
    // they landed.
    var first: ?usize = null;
    var last: usize = 0;
    var inked: usize = 0;
    var x: usize = 0;
    while (x < c.w) : (x += 1) {
        var y: usize = 0;
        while (y < c.h) : (y += 1) {
            const p = c.px[(y * @as(usize, c.w) + x) * 4 ..][0..3];
            if (p[0] > 40 or p[2] > 40) {
                inked += 1;
                if (first == null) first = x;
                last = x;
            }
        }
    }
    try std.testing.expect(inked > 200);

    const f = first.?;
    const span = last - f;
    const third = @max(@as(usize, 1), span / 3);

    // Means, not extremes: the ramp's endpoints are pure red and pure blue, so
    // the MAX of each channel is ~255 at both ends and compares nothing.
    var lr: usize = 0;
    var lb: usize = 0;
    var ln: usize = 0;
    var rr: usize = 0;
    var rb: usize = 0;
    var rn: usize = 0;
    x = f;
    while (x <= last) : (x += 1) {
        var y: usize = 0;
        while (y < c.h) : (y += 1) {
            const p = c.px[(y * @as(usize, c.w) + x) * 4 ..][0..3];
            if (p[0] <= 40 and p[2] <= 40) continue; // background
            if (x < f + third) {
                lr += p[0];
                lb += p[2];
                ln += 1;
            } else if (x > last - third) {
                rr += p[0];
                rb += p[2];
                rn += 1;
            }
        }
    }
    try std.testing.expect(ln > 0 and rn > 0);
    const left_red = lr / ln;
    const right_red = rr / rn;
    const left_blue = lb / ln;
    const right_blue = rb / rn;
    // The ramp must actually run ACROSS the run, not restart per glyph.
    try std.testing.expect(left_red > right_red + 20);
    try std.testing.expect(right_blue > left_blue + 20);
}

test "a blit composites by source alpha instead of stamping it" {
    const gpa = std.testing.allocator;
    var dst = try Canvas.init(gpa, 4, 1);
    defer dst.deinit();
    dst.clear(.{ .r = 255, .g = 255, .b = 255 });

    var src = try Canvas.init(gpa, 4, 1);
    defer src.deinit();
    src.clear(.{ .r = 0, .g = 0, .b = 0 });
    // 0: half-alpha black -- must land halfway between white and black
    src.px[0] = 0;
    src.px[1] = 0;
    src.px[2] = 0;
    src.px[3] = 128;
    // 1: fully transparent, loud colour -- must not touch the destination
    src.px[4] = 255;
    src.px[5] = 0;
    src.px[6] = 255;
    src.px[7] = 0;
    // 2: opaque red -- must be an exact copy
    src.px[8] = 255;
    src.px[9] = 0;
    src.px[10] = 0;
    src.px[11] = 255;

    dst.blitFrom(&src, .{ 0, 0 });

    // 128/255 over white. Not 127: `blendPixel` truncates rather than rounds,
    // so it lands on 126, and a blit that disagreed with the paint path by one
    // byte would be a visible seam wherever an image abuts a quad. That
    // equivalence is asserted directly below rather than trusted here.
    try std.testing.expectEqual(@as(u8, 126), dst.px[0]);
    try std.testing.expectEqual(@as(u8, 255), dst.px[3]);
    // invisible source pixels leave the destination pristine
    try std.testing.expectEqual(@as(u8, 255), dst.px[4]);
    try std.testing.expectEqual(@as(u8, 255), dst.px[5]);
    try std.testing.expectEqual(@as(u8, 255), dst.px[6]);
    // opaque source pixels copy exactly
    try std.testing.expectEqual(@as(u8, 255), dst.px[8]);
    try std.testing.expectEqual(@as(u8, 0), dst.px[9]);
}

test "a blitted pixel and a painted pixel of the same alpha agree" {
    const gpa = std.testing.allocator;
    const half = elmz.Color{ .r = 0, .g = 0, .b = 0, .a = 128 };

    // painted: the normal quad path
    var painted = try Canvas.init(gpa, 1, 1);
    defer painted.deinit();
    painted.clear(.{ .r = 255, .g = 255, .b = 255 });
    painted.blendPixel(0, 0, half);

    // blitted: a one-pixel canvas with the same colour composited in
    var blitted = try Canvas.init(gpa, 1, 1);
    defer blitted.deinit();
    blitted.clear(.{ .r = 255, .g = 255, .b = 255 });

    var src = try Canvas.init(gpa, 1, 1);
    defer src.deinit();
    src.px[0] = half.r;
    src.px[1] = half.g;
    src.px[2] = half.b;
    src.px[3] = half.a;
    blitted.blitFrom(&src, .{ 0, 0 });

    try std.testing.expectEqualSlices(u8, painted.px, blitted.px);
}

test "an opaque blit is still a byte-exact copy" {
    const gpa = std.testing.allocator;
    var dst = try Canvas.init(gpa, 3, 2);
    defer dst.deinit();
    dst.clear(.{ .r = 7, .g = 8, .b = 9 });

    var src = try Canvas.init(gpa, 3, 2);
    defer src.deinit();
    src.clear(.{ .r = 200, .g = 100, .b = 50 });
    // a non-uniform second row, so a row-offset bug cannot pass
    const row1: usize = @as(usize, src.w) * 4;
    src.px[row1 + 0] = 1;
    src.px[row1 + 5] = 2;

    dst.blitFrom(&src, .{ 0, 0 });
    try std.testing.expectEqualSlices(u8, src.px, dst.px);
}

test "compositing onto a transparent canvas keeps the colour, not black" {
    const gpa = std.testing.allocator;
    // init() memsets to zero, so this destination starts at alpha 0 -- the case
    // a blend that forgets to normalise by the OUTPUT alpha turns into black.
    var dst = try Canvas.init(gpa, 1, 1);
    defer dst.deinit();

    var src = try Canvas.init(gpa, 1, 1);
    defer src.deinit();
    src.px[0] = 0;
    src.px[1] = 200;
    src.px[2] = 0;
    src.px[3] = 128;

    dst.blitFrom(&src, .{ 0, 0 });
    try std.testing.expectEqual(@as(u8, 0), dst.px[0]);
    try std.testing.expectEqual(@as(u8, 200), dst.px[1]);
    try std.testing.expectEqual(@as(u8, 128), dst.px[3]);
}

test "a blit clipped by the destination edge drops the rest" {
    const gpa = std.testing.allocator;
    var dst = try Canvas.init(gpa, 2, 2);
    defer dst.deinit();
    dst.clear(.{ .r = 0, .g = 0, .b = 0 });

    var src = try Canvas.init(gpa, 4, 4);
    defer src.deinit();
    src.clear(.{ .r = 255, .g = 0, .b = 0 });

    dst.blitFrom(&src, .{ 1, 1 });
    // only the source's top-left pixel lands, at the destination's far corner
    try std.testing.expectEqual(@as(u8, 255), dst.px[((1 * 2) + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0), dst.px[0]);

    // an origin outside the destination is a no-op, not a crash
    dst.blitFrom(&src, .{ 9, 9 });
    dst.blitFrom(&src, .{ 2, 0 });
}

test "the default bakes, and an explicit .sdf never touches the cache" {
    var c = try Canvas.init(std.testing.allocator, 200, 160);
    defer c.deinit();

    const rect = elmz.Rect{ .x = 60, .y = 50, .w = 80, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const color = elmz.Color{ .r = 255, .g = 200, .b = 0, .a = 220 };
    c.clear(elmz.Color{ .r = 20, .g = 20, .b = 20, .a = 255 });

    // A small blur used to be handed to the distance field, on the argument
    // that baking a mask would cost more than the ramp saved. It does not any
    // more: a template bake is small and independent of the silhouette.
    c.halo(rect, 8, .{ .color = color, .blur = 6, .mode = .glow }, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 1), c.bakes);

    // A different blur is a different stencil, and the second draw of it must
    // find the first rather than bake again. `bakes` is what tells a hit from
    // a re-bake; the entry count alone cannot.
    c.halo(rect, 8, .{ .color = color, .blur = 24, .mode = .glow }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.bakes);
    c.halo(rect, 8, .{ .color = color, .blur = 24, .mode = .glow }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.bakes);

    // ...while an explicit `.sdf` must not consult the cache at all. This is
    // the precedence the switch exists for: the default is not an override.
    //
    // The silhouette here is deliberately DIFFERENT from the ones above. Asking
    // for `.sdf` on the same geometry would find the existing stencil and leave
    // the count unchanged even if the baked path ran -- a cache hit is not
    // evidence about dispatch. A fresh shape is: if `.sdf` fell through to
    // baked, this draw would have to build stencil number three.
    c.halo(elmz.Rect{ .x = 20, .y = 20, .w = 60, .h = 40 }, 8, .{ .color = color, .blur = 24, .mode = .glow, .quality = .sdf }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.bakes);
}

test "the baked stencil and the distance field agree" {
    var a = try Canvas.init(std.testing.allocator, 200, 160);
    defer a.deinit();
    var b = try Canvas.init(std.testing.allocator, 200, 160);
    defer b.deinit();
    a.clear(elmz.Color{ .r = 24, .g = 24, .b = 30, .a = 255 });
    b.clear(elmz.Color{ .r = 24, .g = 24, .b = 30, .a = 255 });

    const rect = elmz.Rect{ .x = 60, .y = 50, .w = 80, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const base = elmz.Halo{
        .color = .{ .r = 255, .g = 200, .b = 0, .a = 220 },
        .blur = 20,
        .spread = 2,
        .offset = .{ 0, 6 },
        .mode = .outer_glow,
    };
    a.halo(rect, 10, .{ .color = base.color, .blur = base.blur, .spread = base.spread, .offset = base.offset, .mode = base.mode, .quality = .sdf }, clip);
    b.halo(rect, 10, .{ .color = base.color, .blur = base.blur, .spread = base.spread, .offset = base.offset, .mode = base.mode, .quality = .baked }, clip);

    // Same silhouette, two renderers of it. Quantising coverage to a byte is
    // the only licence to differ, so anything past rounding is a real drift.
    var worst: u32 = 0;
    var off: usize = 0;
    for (a.px, b.px) |x, y| {
        const d = @abs(@as(i32, x) - @as(i32, y));
        if (d > worst) worst = d;
        if (d > 2) off += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expect(worst <= 2);
}
test "nine slices: differently sized silhouettes share a single stencil" {
    var c = try Canvas.init(std.testing.allocator, 700, 320);
    defer c.deinit();
    c.clear(elmz.Color{ .r = 18, .g = 18, .b = 22, .a = 255 });
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 700, .h = 320 };
    const color = elmz.Color{ .r = 120, .g = 200, .b = 255, .a = 200 };

    // Three widths, one radius and blur. Before slicing these were three
    // stencils, and a view with a hundred glowing rows baked all hundred --
    // every frame, since eight entries cannot hold a hundred sizes.
    const widths = [_]f32{ 120, 260, 420 };
    for (widths, 0..) |w, i| {
        c.halo(.{
            .x = 20,
            .y = 20 + @as(f32, @floatFromInt(i)) * 80,
            .w = w,
            .h = 50,
        }, 8, .{ .color = color, .blur = 26, .mode = .glow, .quality = .baked }, clip);
    }
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    try std.testing.expectEqual(@as(i32, 0), c.masks.items[0].sw);

    // A silhouette smaller than two corner bands cannot be sliced -- the
    // corners would overlap -- so it keeps a full bake of its own.
    c.halo(.{ .x = 20, .y = 260, .w = 12, .h = 12 }, 8, .{ .color = color, .blur = 26, .mode = .glow, .quality = .baked }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expect(c.masks.items[1].sw > 0);
}

test "a stretched stencil still agrees with the distance field when large" {
    var a = try Canvas.init(std.testing.allocator, 520, 300);
    defer a.deinit();
    var b = try Canvas.init(std.testing.allocator, 520, 300);
    defer b.deinit();
    a.clear(elmz.Color{ .r = 22, .g = 22, .b = 28, .a = 255 });
    b.clear(elmz.Color{ .r = 22, .g = 22, .b = 28, .a = 255 });

    // Long edges, so the middle of each edge is stretched far past the baked
    // corner -- the part of a 9-slice that is actually an approximation.
    const rect = elmz.Rect{ .x = 60, .y = 90, .w = 380, .h = 110 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 520, .h = 300 };
    const h = elmz.Halo{
        .color = .{ .r = 255, .g = 190, .b = 90, .a = 210 },
        .blur = 30,
        .spread = 3,
        .offset = .{ 0, 8 },
        .mode = .outer_glow,
    };
    a.halo(rect, 14, .{ .color = h.color, .blur = h.blur, .spread = h.spread, .offset = h.offset, .mode = h.mode, .quality = .sdf }, clip);
    b.halo(rect, 14, .{ .color = h.color, .blur = h.blur, .spread = h.spread, .offset = h.offset, .mode = h.mode, .quality = .baked }, clip);

    var worst: u32 = 0;
    var off: usize = 0;
    for (a.px, b.px) |x, y| {
        const d = @abs(@as(i32, x) - @as(i32, y));
        if (d > worst) worst = d;
        if (d > 2) off += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expect(worst <= 2);
}

fn testPx(c: *Canvas, x: usize, y: usize) [4]u8 {
    const o = (y * c.w + x) * 4;
    return c.px[o..][0..4].*;
}

/// RGB only. A freshly `init`ed canvas starts at alpha 0 and the opaque fast path
/// in `blendPixel` leaves destination alpha alone, which is correct for a canvas
/// that is cleared and painted as a whole -- colour is what these tests are about.
fn testRgb(c: *Canvas, x: usize, y: usize) [3]u8 {
    const p = testPx(c, x, y);
    return .{ p[0], p[1], p[2] };
}

test "the stencil and the distance field put the ramp in the same place" {
    const gpa = std.testing.allocator;

    // Where does coverage cross half, scanning inward from outside the shape?
    // Interpolated between samples, so the answer is not quantised to a pixel.
    const Spot = struct {
        fn cross(c: *Canvas, sx: i32, sy: i32, dx: i32, dy: i32, steps: usize) f32 {
            var prev: f32 = -1;
            var i: usize = 0;
            while (i < steps) : (i += 1) {
                const k: i32 = @intCast(i);
                const x: usize = @intCast(sx + dx * k);
                const y: usize = @intCast(sy + dy * k);
                if (x >= 260 or y >= 200) return -1;
                const v: f32 = @floatFromInt(testRgb(c, x, y)[0]);
                if (v >= 128) {
                    if (prev < 0) return @floatFromInt(i);
                    return @as(f32, @floatFromInt(i - 1)) + (128 - prev) / (v - prev);
                }
                prev = v;
            }
            return -1;
        }
        fn edges(w: f32, h: f32, spread: f32, q: elmz.Halo.Quality) ![4]f32 {
            const clip = elmz.Rect{ .x = 0, .y = 0, .w = 260, .h = 200 };
            const rect = elmz.Rect{ .x = 40, .y = 40, .w = w, .h = h };
            var c = try Canvas.init(gpa, 260, 200);
            defer c.deinit();
            const r = c.renderer();
            r.quad(clip, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
            r.halo(rect, 10, .{
                .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
                .blur = 14,
                .spread = spread,
                .mode = .glow,
                .quality = q,
            }, clip);
            const midy: i32 = @intFromFloat(40 + h * 0.5);
            const midx: i32 = @intFromFloat(40 + w * 0.5);
            const rx: i32 = @intFromFloat(40 + w);
            const by: i32 = @intFromFloat(40 + h);
            const l = @This().cross(&c, 10, midy, 1, 0, 45);
            const rr = @This().cross(&c, rx + 30, midy, -1, 0, 45);
            const t = @This().cross(&c, midx, 15, 0, 1, 40);
            const bb = @This().cross(&c, midx, by + 25, 0, -1, 40);
            if (l < 0 or rr < 0 or t < 0 or bb < 0) return error.NoCrossing;
            return .{ 10 + l, @as(f32, @floatFromInt(rx + 30)) - rr, 15 + t, @as(f32, @floatFromInt(by + 25)) - bb };
        }
    };

    // 74x34 is under 2*corner at blur 14 / radius 10, so it takes the whole-mask
    // bake; 120x80 is over it and takes the nine-slice template. A 34px button
    // is what the examples actually draw, so both branches need covering.
    inline for (.{ .{ 74, 34 }, .{ 120, 80 } }) |sz| {
        inline for (.{ 0, 2, 4 }) |sp| {
            const sdf = try Spot.edges(sz[0], sz[1], sp, .sdf);
            const baked = try Spot.edges(sz[0], sz[1], sp, .baked);
            for (sdf, baked) |a, b| {
                // One pixel of slack, on a ramp that spans blur = 14. The
                // measured disagreement is 0.03px -- the coverage byte's own
                // rounding -- so this catches a displaced silhouette while
                // tolerating the quantisation that will never be removed.
                try std.testing.expectApproxEqAbs(a, b, 1.0);
            }
        }
    }
}

test "a wide inner glow keeps the corners it is attached to" {
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const rect = elmz.Rect{ .x = 40, .y = 40, .w = 80, .h = 60 };

    // (42,70) is a pixel inside the left edge at mid-height; (44,44) is 4px in
    // from the top-left corner on the diagonal. A rim light has to be bright at
    // both: it is attached to the shape, and the shape has corners. What the
    // blend changes is further in, where the falloff is decaying -- the outline
    // is no longer legible there and the pool rounds off.
    inline for (.{ 30, 14 }) |blur| {
        var c = try Canvas.init(gpa, 200, 160);
        defer c.deinit();
        const r = c.renderer();
        r.quad(clip, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
        r.halo(rect, 8, .{
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .blur = blur,
            .mode = .inner_glow,
            .quality = .sdf,
        }, clip);

        const edge: f32 = @floatFromInt(testRgb(&c, 42, 70)[0]);
        const corner: f32 = @floatFromInt(testRgb(&c, 44, 44)[0]);
        const middle: f32 = @floatFromInt(testRgb(&c, 80, 70)[0]);

        // The rim is on the corner at every width. Uniformly blending the metric
        // (the first attempt) drove this to zero and hollowed the button out.
        try std.testing.expect(corner > 150);
        // ...and it decays: this is a rim, not a wash.
        try std.testing.expect(edge > middle);
    }
}

test "an outer rim is feathered where it meets the element" {
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const rect = elmz.Rect{ .x = 40, .y = 40, .w = 80, .h = 60 };

    var c = try Canvas.init(gpa, 200, 160);
    defer c.deinit();
    const r = c.renderer();
    r.quad(rect, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
    r.halo(rect, 8, .{
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .blur = 24,
        .spread = 3,
        .mode = .outer_glow,
        .quality = .sdf,
    }, clip);

    // A binary inside/outside cut gives one step from fill to rim at the shape's
    // boundary -- the worst place for it is the rounded corner, where the fill was
    // antialiased and the rim was not. One pixel outside the corner is partially
    // covered by the element, so the rim has to be partial there too.
    const just_outside: f32 = @floatFromInt(testRgb(&c, 39, 39)[0]);
    const clear_of_it: f32 = @floatFromInt(testRgb(&c, 30, 30)[0]);
    try std.testing.expect(just_outside > clear_of_it);
    try std.testing.expect(just_outside < 255);
}

test "an inner glow drops fast off the edge and then converges" {
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const rect = elmz.Rect{ .x = 40, .y = 40, .w = 80, .h = 60 };

    inline for (.{ .sdf, .baked }) |q| {
        var c = try Canvas.init(gpa, 200, 160);
        defer c.deinit();
        const r = c.renderer();
        r.quad(clip, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
        // Opaque white on black, so the red channel IS the coverage.
        r.halo(rect, 8, .{
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .blur = 14,
            .mode = .inner_glow,
            .quality = q,
        }, clip);

        const y: usize = 70; // mid-height, clear of the corners
        const edge: f32 = @floatFromInt(testRgb(&c, 41, y)[0]);
        const half: f32 = @floatFromInt(testRgb(&c, 47, y)[0]);
        const deep: f32 = @floatFromInt(testRgb(&c, 53, y)[0]);
        const gone: f32 = @floatFromInt(testRgb(&c, 55, y)[0]);

        // Full at the silhouette: d = -1.5, u = 0.107, (1-u)^2 = 0.797.
        try std.testing.expectApproxEqAbs(@as(f32, 203), edge, 12);
        // Halfway in it is nearly spent -- 0.216, not the 0.464 a linear ramp gives.
        // This is the assertion that distinguishes "drops fast" from "drops evenly".
        try std.testing.expectApproxEqAbs(@as(f32, 55), half, 12);
        // And it converges rather than stopping: still a trace, close to nothing.
        try std.testing.expect(deep < 6);
        try std.testing.expect(gone < 2);
        // Monotone: no ring, no plateau.
        try std.testing.expect(edge > half and half > deep and deep >= gone);
    }
}

test "a cast shadow fills the strip under its element and never tints the face" {
    // The strip between the element's edge and the offset silhouette is the whole
    // point: cut against the SHAPE instead of the element and that strip is left
    // as bare backdrop, so the shadow reads as a detached smear a few pixels below
    // the card rather than as the card's shadow.
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 220, 180);
    defer c.deinit();
    const r = c.renderer();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 180 };
    const bg = elmz.Color{ .r = 30, .g = 30, .b = 46, .a = 255 };
    const panel = elmz.Color{ .r = 49, .g = 50, .b = 68, .a = 255 };
    r.quad(clip, .{ .solid = bg }, clip);

    const rect = elmz.Rect{ .x = 60, .y = 40, .w = 100, .h = 70 };
    r.quad(rect, .{ .solid = panel }, clip);
    r.halo(rect, 0, .{
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 200 },
        .blur = 24,
        .spread = 4,
        .offset = .{ 0, 12 },
        .light = 0, // clock 0 is overhead, so the shadow is thrown downward
        .mode = .outer_glow,
    }, clip);

    // 1. The face is untouched. An outer rim is cut against the element, so a
    //    displaced silhouette cannot smear across what it is cast by.
    try std.testing.expectEqual([3]u8{ 49, 50, 68 }, testRgb(&c, 110, 75));

    // 2. The strip under the element is shadowed, not bare backdrop. y = 116 is
    //    6px below the element's bottom edge and inside the offset silhouette.
    const strip = testPx(&c, 110, 116);
    try std.testing.expect(strip[0] < 20);

    // 3. The lit side is not darkened as much as the cast side, at the same
    //    distance from the element -- that is what the light angle buys.
    const above = testPx(&c, 110, 34);
    const below = testPx(&c, 110, 128);
    try std.testing.expect(above[0] > below[0]);

    // 4. Far outside the ring, nothing at all.
    try std.testing.expectEqual([3]u8{ 30, 30, 46 }, testRgb(&c, 8, 8));
}

test "a frost blurs what is behind it and leaves everything else alone" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 200, 140);
    defer c.deinit();
    const r = c.renderer();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 140 };

    // Hard 3px black/white stripes: a blur that does nothing is obvious, and a
    // blur that samples outside its rect darkens the edges as well.
    var x: usize = 0;
    while (x < 200) : (x += 1) {
        const on = (x / 3) % 2 == 0;
        const v: u8 = if (on) 0 else 255;
        r.quad(.{ .x = @floatFromInt(x), .y = 0, .w = 1, .h = 140 }, .{ .solid = .{ .r = v, .g = v, .b = v, .a = 255 } }, clip);
    }

    const outside_before = testRgb(&c, 20, 70);

    r.frost(.{ .x = 50, .y = 40, .w = 100, .h = 60 }, 0, 8, clip);

    // Inside: the extremes are pulled toward the mean in both directions, which is
    // what a blur is. A no-op frost leaves these at 0 and 255.
    const after_a: i32 = testRgb(&c, 100, 70)[0];
    const after_b: i32 = testRgb(&c, 103, 70)[0];
    // One of the pair was a white stripe and one a black stripe; a blur pulls both
    // toward the mean, so assert on the GAP rather than on each value.
    try std.testing.expect(@max(after_a, after_b) - @min(after_a, after_b) < 90);

    // Outside the rect: byte-identical. This is the check a missing clip fails.
    try std.testing.expectEqual(outside_before, testRgb(&c, 20, 70));

    // No dark rim at the rect's own border: the corner pixel of the frosted area is
    // a blend of real colours, not the zero-padding of a buffer that ran out.
    const edge = testRgb(&c, 51, 41);
    try std.testing.expect(edge[0] > 20 and edge[0] < 235);
}

test "a light source throws the ramp further on the away side" {
    // The asymmetry is the entire reason `light` exists: an offset alone displaces
    // the silhouette but leaves the falloff identical on every edge, which reads as
    // a copy rather than as cast light.
    const gpa = std.testing.allocator;
    const rect = elmz.Rect{ .x = 60, .y = 40, .w = 100, .h = 70 };

    const Case = struct {
        fn bands(light: ?f32, above: *usize, below: *usize) !void {
            var c = try Canvas.init(gpa, 220, 180);
            defer c.deinit();
            const r = c.renderer();
            const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 180 };
            const bg = elmz.Color{ .r = 30, .g = 30, .b = 46, .a = 255 };
            r.quad(clip, .{ .solid = bg }, clip);
            r.quad(rect, .{ .solid = .{ .r = 49, .g = 50, .b = 68, .a = 255 } }, clip);
            r.halo(rect, 0, .{
                .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                .blur = 24,
                .offset = .{ 0, 8 },
                .light = light,
                .mode = .outer_glow,
            }, clip);

            // `a` holds the FARTHEST dark row above the element, so the extent is
            // how far the ramp reached -- not the last dark row, which is always the
            // one next to the element and would report the same number every time.
            var a: usize = 40;
            var y: usize = 0;
            while (y < 40) : (y += 1) {
                if (testRgb(&c, 110, y)[0] < 29 and y < a) a = y;
            }
            var b: usize = 110;
            y = 111;
            while (y < 180) : (y += 1) {
                if (testRgb(&c, 110, y)[0] < 29) b = y;
            }
            above.* = 40 - a;
            below.* = b - 110;
        }
    };

    var wa: usize = 0;
    var wb: usize = 0;
    try Case.bands(0, &wa, &wb);
    var oa: usize = 0;
    var ob: usize = 0;
    try Case.bands(null, &oa, &ob);

    // Compared against the SAME offset with no light, because the offset alone
    // already lengthens the band it points at. Light must move each side in its own
    // direction: longer away from the source, shorter toward it.
    try std.testing.expect(wb > ob);
    try std.testing.expect(wa < oa);
    try std.testing.expect(wb > wa);
}

test "a frame painted with opaque colours exports an opaque alpha channel" {
    // The failure this catches is invisible to every other test: RGB is correct,
    // and the PNG is a fully transparent image that renders black everywhere.
    // src-over onto a cleared canvas leaves the destination alpha at 0 unless the
    // opaque path writes it, so a frame made only of opaque fills exports as
    // nothing at all.
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 32, .h = 24 };
    var c = try Canvas.init(gpa, 32, 24);
    defer c.deinit();
    const r = c.renderer();

    r.quad(clip, .{ .solid = elmz.Color.rgbHex(0x1e1e2e) }, clip);
    // Both opaque paths: the row fill above, a per-pixel blend here.
    r.halo(.{ .x = 8, .y = 6, .w = 12, .h = 10 }, 3, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .blur = 2, .mode = .glow }, clip);

    for (0..24) |y| {
        for (0..32) |x| {
            const a = c.px[(y * 32 + x) * 4 + 3];
            try std.testing.expectEqual(@as(u8, 255), a);
        }
    }

    // A translucent fill over the opaque result must not un-opaque it: src-over
    // onto alpha 255 stays 255.
    r.quad(clip, .{ .solid = .{ .r = 255, .g = 0, .b = 0, .a = 128 } }, clip);
    try std.testing.expectEqual(@as(u8, 255), c.px[(5 * 32 + 5) * 4 + 3]);
}

// The blind spot, stated as a test. An opaque frame used to export with alpha 0
// on every pixel -- correct RGB, invisible in every viewer -- because the fast
// paths wrote r, g, b and skipped alpha. The rasteriser test above caught the
// canvas half; this one catches the FILE half, which is where it was seen: a
// rendered PNG that opened as a black rectangle.
test "a painted frame exports opaque pixels through the PNG encoder" {
    var c = try Canvas.init(testing.allocator, 12, 6);
    defer c.deinit();
    const base = elmz.Color{ .r = 30, .g = 40, .b = 50, .a = 255 };
    const over = elmz.Color{ .r = 200, .g = 120, .b = 60, .a = 255 };
    c.fillRect(.{ .x = 0, .y = 0, .w = 12, .h = 6 }, .{ .solid = base });
    // A second opaque quad through the blending path, so both routes are covered.
    c.fillRect(.{ .x = 4, .y = 2, .w = 4, .h = 2 }, .{ .solid = over });

    const png = try c.encodePng(testing.allocator);
    defer testing.allocator.free(png);
    const px = try decodeStoredPng(testing.allocator, png);
    defer testing.allocator.free(px);

    try testing.expectEqual(@as(usize, 12 * 6 * 4), px.len);
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 255), px[i + 3]);
    }
    // And the bytes are the ones painted, not a uniform fill.
    const at = struct {
        fn at(b: []const u8, x: usize, y: usize) [4]u8 {
            const o = (y * 12 + x) * 4;
            return .{ b[o], b[o + 1], b[o + 2], b[o + 3] };
        }
    };
    try testing.expectEqual([4]u8{ 200, 120, 60, 255 }, at.at(px, 5, 3));
    try testing.expectEqual([4]u8{ 30, 40, 50, 255 }, at.at(px, 0, 0));
}
