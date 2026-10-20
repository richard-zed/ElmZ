//! Software backend for elmz: an RGB framebuffer with a 5x7 bitmap font, plus a
//! dependency-free PNG encoder. This is the backend you want while you are
//! still arguing with layout; swap in a GPU backend later behind the same
//! `elmz.Renderer` vtable.

const std = @import("std");
const elmz = @import("elmz");
const ttf = @import("ttf.zig");
const Allocator = std.mem.Allocator;

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

    /// Below this blur the distance field is cheaper than a mask: the ramp has
    /// few pixels left to cache, and baking would cost more than it saves.
    /// Only `.auto` consults it -- an explicit `quality` overrules it.
    pub const sdf_crossover: f32 = 10;

    const Mask = struct {
        sw: i32,
        sh: i32,
        r: f32,
        blur: f32,
        rw: u32,
        rh: u32,
        px: []u8, // coverage, one byte per pixel
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
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        const dst_r: f32 = @floatFromInt(self.px[i + 0]);
        const dst_g: f32 = @floatFromInt(self.px[i + 1]);
        const dst_b: f32 = @floatFromInt(self.px[i + 2]);
        self.px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * a + dst_r * (1 - a));
        self.px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * a + dst_g * (1 - a));
        self.px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * a + dst_b * (1 - a));
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
        var y = sp.y0;
        switch (fill) {
            // The solid case hoists the colour out of the loop entirely: this
            // is still the path every plain background takes, and it must not
            // pay for gradients existing.
            .solid => |c| {
                if (c.a == 0) return;
                while (y < sp.y1) : (y += 1) {
                    var x = sp.x0;
                    while (x < sp.x1) : (x += 1) self.blendPixel(x, y, c);
                }
            },
            .linear => |g| {
                // A purely vertical axis makes the colour constant along every
                // scanline, so it is sampled once per ROW rather than per
                // pixel -- the row-wide fill survives untouched.
                if (g.to[1] != g.from[1] and g.to[0] == g.from[0]) {
                    const xm: f32 = @floatFromInt(sp.x0);
                    while (y < sp.y1) : (y += 1) {
                        const c = fill.colorAt(rect, xm, @as(f32, @floatFromInt(y)) + 0.5);
                        if (c.a == 0) continue;
                        var x = sp.x0;
                        while (x < sp.x1) : (x += 1) self.blendPixel(x, y, c);
                    }
                } else {
                    while (y < sp.y1) : (y += 1) {
                        const ym = @as(f32, @floatFromInt(y)) + 0.5;
                        var x = sp.x0;
                        while (x < sp.x1) : (x += 1) {
                            const c = fill.colorAt(rect, @as(f32, @floatFromInt(x)) + 0.5, ym);
                            if (c.a == 0) continue;
                            self.blendPixel(x, y, c);
                        }
                    }
                }
            },
            .radial => {
                while (y < sp.y1) : (y += 1) {
                    const ym = @as(f32, @floatFromInt(y)) + 0.5;
                    var x = sp.x0;
                    while (x < sp.x1) : (x += 1) {
                        const c = fill.colorAt(rect, @as(f32, @floatFromInt(x)) + 0.5, ym);
                        if (c.a == 0) continue;
                        self.blendPixel(x, y, c);
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
        // Explicit beats the heuristic. A quality setting the library can
        // second-guess is not an escape hatch, so `.auto` is the only mode the
        // crossover is allowed to tune.
        const use_sdf = switch (h.quality) {
            .sdf => true,
            .baked => false,
            .auto => h.blur < sdf_crossover,
        };
        if (use_sdf) return self.haloSdf(rect, corner, h, clip);
        self.haloBaked(rect, corner, h, clip);
    }

    fn haloSdf(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const blur = @max(h.blur, 0);
        // The silhouette the ramp runs away from, after spread and offset.
        const shape = elmz.Rect{
            .x = rect.x + h.offset[0] - h.spread,
            .y = rect.y + h.offset[1] - h.spread,
            .w = rect.w + h.spread * 2,
            .h = rect.h + h.spread * 2,
        };
        if (shape.w <= 0 or shape.h <= 0) return;
        const r = @min(@max(corner + h.spread, 0), @min(shape.w, shape.h) * 0.5);
        const hx = shape.w * 0.5 - r;
        const hy = shape.h * 0.5 - r;
        const cx = shape.x + shape.w * 0.5;
        const cy = shape.y + shape.h * 0.5;

        // Ring bounds: the shape grown by the falloff, plus one pixel for the
        // antialiased edge itself.
        const grow = blur * 0.5 + 1;
        const ring = elmz.Rect{
            .x = shape.x - grow,
            .y = shape.y - grow,
            .w = shape.w + grow * 2,
            .h = shape.h + grow * 2,
        };
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
                if (d > blur * 0.5 or d < -blur * 0.5) continue;
                const cov = if (blur <= 0) 1 else std.math.clamp(0.5 - d / blur, 0, 1);
                if (cov > 0) self.blendCoverage(x, y, h.color, cov);
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
        const shape = elmz.Rect{
            .x = rect.x + h.offset[0] - h.spread,
            .y = rect.y + h.offset[1] - h.spread,
            .w = rect.w + h.spread * 2,
            .h = rect.h + h.spread * 2,
        };
        if (shape.w <= 0 or shape.h <= 0) return;
        const r = @min(@max(corner + h.spread, 0), @min(shape.w, shape.h) * 0.5);
        const m = self.maskFor(
            @intFromFloat(@round(shape.w)),
            @intFromFloat(@round(shape.h)),
            r,
            blur,
        ) orelse return self.haloSdf(rect, corner, h, clip);

        const grow = blur * 0.5 + 1;
        const ox: i64 = @intFromFloat(@round(shape.x - grow));
        const oy: i64 = @intFromFloat(@round(shape.y - grow));
        const ring = elmz.Rect{
            .x = @floatFromInt(ox),
            .y = @floatFromInt(oy),
            .w = @floatFromInt(m.rw),
            .h = @floatFromInt(m.rh),
        };
        const sp = self.clipSpan(ring, clip) orelse return;

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const j = y - oy;
            if (j < 0 or j >= m.rh) continue;
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const i = x - ox;
                if (i < 0 or i >= m.rw) continue;
                const a = m.px[@as(usize, @intCast(j)) * m.rw + @as(usize, @intCast(i))];
                if (a == 0) continue;
                self.blendCoverage(x, y, h.color, @as(f32, @floatFromInt(a)) / 255.0);
            }
        }
    }

    /// The stencil for one silhouette, built on first use and kept.
    ///
    /// COST NOTE: the mask is full size, not 9-sliced. Slicing is what makes a
    /// huge blurred panel cheap; without it a bake saves the per-frame distance
    /// math but not the area. Slicing needs the centre and the four edges kept
    /// separately, so it is a second data shape, not a flag on this one.
    fn maskFor(self: *Self, sw: i32, sh: i32, r: f32, blur: f32) ?*Mask {
        for (self.masks.items) |*m| {
            if (m.sw == sw and m.sh == sh and m.r == r and m.blur == blur) return m;
        }
        if (sw <= 0 or sh <= 0) return null;
        const grow = blur * 0.5 + 1;
        const rw_f = @as(f32, @floatFromInt(sw)) + grow * 2;
        const rh_f = @as(f32, @floatFromInt(sh)) + grow * 2;
        const rw: u32 = @intFromFloat(@ceil(rw_f));
        const rh: u32 = @intFromFloat(@ceil(rh_f));
        if (@as(u64, rw) * @as(u64, rh) > 4_000_000) return null;
        const px = self.gpa.alloc(u8, @as(usize, rw) * rh) catch return null;

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
                var cov: f32 = 0;
                if (d <= blur * 0.5 and d >= -blur * 0.5) {
                    cov = if (blur <= 0) 1 else std.math.clamp(0.5 - d / blur, 0, 1);
                }
                px[@as(usize, j) * rw + i] = @intFromFloat(cov * 255.0 + 0.5);
            }
        }

        if (self.masks.items.len >= 8) {
            const old = self.masks.orderedRemove(0);
            self.gpa.free(old.px);
        }
        self.masks.append(self.gpa, .{ .sw = sw, .sh = sh, .r = r, .blur = blur, .rw = rw, .rh = rh, .px = px }) catch {
            self.gpa.free(px);
            return null;
        };
        return &self.masks.items[self.masks.items.len - 1];
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
        .measure_text = vtMeasure,
        .wrap_text = vtWrap,
    };

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

test "a quad larger than the canvas is clipped, not corrupting" {
    var c = try Canvas.init(testing.allocator, 8, 8);
    defer c.deinit();
    c.fillRect(.{ .x = -50, .y = -50, .w = 500, .h = 500 }, .{ .solid = .{ .r = 9, .g = 9, .b = 9, .a = 255 } });
    var i: usize = 0;
    while (i < c.px.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 9), c.px[i]);
        try testing.expectEqual(@as(u8, 9), c.px[i + 2]);
        try testing.expectEqual(@as(u8, 0), c.px[i + 3]); // alpha untouched
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

test "auto takes the distance field below the crossover and a stencil above" {
    var c = try Canvas.init(std.testing.allocator, 200, 160);
    defer c.deinit();

    const rect = elmz.Rect{ .x = 60, .y = 50, .w = 80, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const color = elmz.Color{ .r = 255, .g = 200, .b = 0, .a = 220 };
    c.clear(elmz.Color{ .r = 20, .g = 20, .b = 20, .a = 255 });

    // Under the crossover there is nothing worth caching.
    c.halo(rect, 8, .{ .color = color, .blur = 6, .mode = .glow, .quality = .auto }, clip);
    try std.testing.expectEqual(@as(usize, 0), c.masks.items.len);

    // Over it, one stencil -- and the second draw must find it, not build it.
    c.halo(rect, 8, .{ .color = color, .blur = 24, .mode = .glow, .quality = .auto }, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    c.halo(rect, 8, .{ .color = color, .blur = 24, .mode = .glow, .quality = .auto }, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);

    // ...while an explicit `.sdf` must NOT consult it. This is the precedence
    // the switch exists for: the threshold is a default, not an override.
    //
    // The silhouette here is deliberately DIFFERENT from the one above. Asking
    // for `.sdf` on the same geometry would find the existing stencil and
    // leave the count unchanged even if the baked path ran -- a cache hit is
    // not evidence about dispatch. A fresh shape is: if `.sdf` fell through to
    // baked, this draw would have to build stencil number two.
    c.halo(elmz.Rect{ .x = 20, .y = 20, .w = 60, .h = 40 }, 8, .{ .color = color, .blur = 24, .mode = .glow, .quality = .sdf }, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
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
        .mode = .shadow,
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
