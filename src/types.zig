//! The vocabulary both halves of elmz share: geometry, paint, and the
//! primitives a renderer consumes.
//!
//! These live below BOTH `software` (which rasterises them) and `elmz` (which
//! produces them). They used to sit inside `elmz.zig`, which forced the
//! renderer to import the runtime upward to name a `Rect`; nothing here refers
//! to a runtime, a theme, or a widget, so moving them down is what lets the
//! composition layer move up without a cycle.
//!
//! No module imports but `std`.

const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgbHex(v: u32) Color {
        return .{
            .r = @intCast((v >> 16) & 0xff),
            .g = @intCast((v >> 8) & 0xff),
            .b = @intCast(v & 0xff),
        };
    }

    /// `0xRRGGBBAA`.
    pub fn rgbaHex(v: u32) Color {
        return .{
            .r = @intCast((v >> 24) & 0xff),
            .g = @intCast((v >> 16) & 0xff),
            .b = @intCast((v >> 8) & 0xff),
            .a = @intCast(v & 0xff),
        };
    }

    /// RGB ONLY, always opaque. There is no eight-digit form: `0x000000ff` is the
    /// number 255, identical to `0x0000ff`, and a magnitude test cannot tell them
    /// apart -- it would parse as blue. Alpha comes from `rgbaHex` or a literal.
    pub fn hex(v: u32) Color {
        return if (v > 0xFFFFFF) rgbaHex(v) else rgbHex(v);
    }
};

pub const Size = struct { w: f32 = 0, h: f32 = 0 };

// ---------------------------------------------------------------------------
// paint: a solid colour is one case of a fill, not the whole type
// ---------------------------------------------------------------------------

/// Gradient stops: up to four colours held as VALUES, with each stop's position implied by
/// how many there are.
pub const Stops = struct {
    colors: [4]Color = @splat(none),
    n: u8 = 0,

    /// The colour of an unused slot. Named rather than written inline because `Color` has
    /// no field defaults, so `.{}` will not do.
    const none: Color = .{ .r = 0, .g = 0, .b = 0 };

    pub fn two(a: Color, b: Color) Stops {
        return .{ .n = 2, .colors = .{ a, b, none, none } };
    }

    pub fn three(a: Color, b: Color, c: Color) Stops {
        return .{ .n = 3, .colors = .{ a, b, c, none } };
    }

    pub fn four(a: Color, b: Color, c: Color, d: Color) Stops {
        return .{ .n = 4, .colors = .{ a, b, c, d } };
    }

    /// Where stop `i` sits along the axis, for a ramp of this many stops.
    fn pos(self: Stops, i: usize) f32 {
        return switch (self.n) {
            2 => if (i == 0) 0 else 1,
            3 => switch (i) {
                0 => 0,
                1 => 0.5,
                else => 1,
            },
            4 => switch (i) {
                0 => 0,
                1 => 0.333,
                2 => 0.667,
                else => 1,
            },
            else => 0,
        };
    }

    /// Sample at `t`. Flat outside the end stops (every toolkit does this), so a rect
    /// taller than its axis does not snap to an edge colour.
    pub fn atFast(self: Stops, t: f32) Color {
        if (self.n == 2) {
            return mix(self.colors[0], self.colors[1], std.math.clamp(t, 0, 1));
        }
        return self.at(std.math.clamp(t, 0, 1));
    }

    pub fn at(self: Stops, t: f32) Color {
        const n: usize = self.n;
        if (n == 0) return .{ .r = 0, .g = 0, .b = 0 };
        if (t <= self.pos(0)) return self.colors[0];
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const b_at = self.pos(i);
            if (t <= b_at) {
                const a_at = self.pos(i - 1);
                const span = b_at - a_at;
                return mix(self.colors[i - 1], self.colors[i], if (span <= 0) 1 else (t - a_at) / span);
            }
        }
        return self.colors[n - 1];
    }

    /// Interpolate in PREMULTIPLIED space. A straight rgb lerp toward a transparent colour
    /// drags the midpoint toward black -- the classic muddy fade.
    fn mix(a: Color, b: Color, u: f32) Color {
        const t = std.math.clamp(u, 0, 1);
        // Two opaque endpoints mix to an opaque colour, and saying so skips
        // the premultiply, the reciprocal and the unpremultiply below. It also
        // keeps the result's alpha at exactly 255, which is what lets the
        // rasteriser take its store path instead of its blend path -- a fact
        // worth three lines, because that is the difference between a 1x fill
        // and a 20x one.
        if (a.a == 255 and b.a == 255) {
            return .{
                .r = clamp255(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * t),
                .g = clamp255(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * t),
                .b = clamp255(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * t),
                .a = 255,
            };
        }
        const aa: f32 = @as(f32, @floatFromInt(a.a)) / 255.0;
        const ba: f32 = @as(f32, @floatFromInt(b.a)) / 255.0;
        const oa = aa + (ba - aa) * t;
        if (oa <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const ar: f32 = @as(f32, @floatFromInt(a.r)) * aa;
        const ag: f32 = @as(f32, @floatFromInt(a.g)) * aa;
        const ab: f32 = @as(f32, @floatFromInt(a.b)) * aa;
        const br: f32 = @as(f32, @floatFromInt(b.r)) * ba;
        const bg2: f32 = @as(f32, @floatFromInt(b.g)) * ba;
        const bb: f32 = @as(f32, @floatFromInt(b.b)) * ba;
        const inv = 1.0 / oa;
        return .{
            .r = clamp255((ar + (br - ar) * t) * inv),
            .g = clamp255((ag + (bg2 - ag) * t) * inv),
            .b = clamp255((ab + (bb - ab) * t) * inv),
            .a = clamp255(oa * 255.0),
        };
    }

    fn clamp255(v: f32) u8 {
        const r = @round(v);
        if (r <= 0) return 0;
        if (r >= 255) return 255;
        return @intFromFloat(r);
    }
};

/// How to paint a shape. `solid` is the common case and keeps the old fast path; the
/// gradient prongs are geometry plus stops and nothing else.
pub const Fill = union(enum) {
    solid: Color,
    linear: Linear,
    radial: Radial,

    pub const Linear = struct {
        from: [2]f32 = .{ 0, 0 },
        to: [2]f32 = .{ 0, 1 },
        stops: Stops = .{},
    };

    pub const Radial = struct {
        center: [2]f32 = .{ 0.5, 0.5 },
        radius: f32 = 0.5,
        stops: Stops = .{},
    };

    /// Vertical, top to bottom. Clock 180.
    pub fn vgrad(a: Color, b: Color) Fill {
        return .{ .linear = .{ .stops = Stops.two(a, b) } };
    }

    /// Horizontal, left to right. Clock 90.
    pub fn hgrad(a: Color, b: Color) Fill {
        return .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 0 }, .stops = Stops.two(a, b) } };
    }

    /// Linear ramp at `deg` degrees on a clock face: clockwise from 12 o'clock, naming the
    /// direction the ramp TRAVELS.
    pub fn angled(deg: f32, a: Color, b: Color) Fill {
        // Clock degrees -> the vector this always used. 0 used to mean "to the
        // right", so subtracting 90 relabels every call site without moving a
        // pixel: the f32 handed to cos/sin is the same number it was before.
        const rad = std.math.degreesToRadians(deg - 90);
        const dx = @cos(rad) * 0.5;
        const dy = @sin(rad) * 0.5;
        return .{ .linear = .{
            .from = .{ 0.5 - dx, 0.5 - dy },
            .to = .{ 0.5 + dx, 0.5 + dy },
            .stops = Stops.two(a, b),
        } };
    }

    /// Diagonal, corner to corner: down and to the right. Clock 135.
    pub fn diag(a: Color, b: Color) Fill {
        return .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 }, .stops = Stops.two(a, b) } };
    }

    pub fn radialFill(center: Color, edge: Color) Fill {
        return .{ .radial = .{ .stops = Stops.two(center, edge) } };
    }

    /// True for the plain-colour case, which is the only one the cheap four-quad border
    /// path can draw correctly.
    pub fn isSolid(self: Fill) bool {
        return switch (self) {
            .solid => true,
            else => false,
        };
    }

    /// The colour of this fill at a point, given the box it is painted into.
    pub fn colorAt(self: Fill, box: Rect, px: f32, py: f32) Color {
        switch (self) {
            .solid => |c| return c,
            .linear => |g| {
                const ax = box.x + g.from[0] * box.w;
                const ay = box.y + g.from[1] * box.h;
                const dx = (box.x + g.to[0] * box.w) - ax;
                const dy = (box.y + g.to[1] * box.h) - ay;
                const len2 = dx * dx + dy * dy;
                const t = if (len2 <= 0) 0 else ((px - ax) * dx + (py - ay) * dy) / len2;
                return g.stops.at(std.math.clamp(t, 0, 1));
            },
            .radial => |g| {
                const cx = box.x + g.center[0] * box.w;
                const cy = box.y + g.center[1] * box.h;
                const r = g.radius * box.w;
                const dx = px - cx;
                const dy = py - cy;
                const t = if (r <= 0) 1 else @sqrt(dx * dx + dy * dy) / r;
                return g.stops.at(std.math.clamp(t, 0, 1));
            },
        }
    }
};

/// How an image occupies its box.
///
/// `.fit` preserves the source aspect; `.stretch` fills the box exactly, even
/// when that distorts. In practice layout has already given an image the right
/// shape (see `Elem.measure`), so `.fit` only does work when a caller forced
/// both width and height.
pub const ImageFit = enum { fit, stretch };

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, p: [2]f32) bool {
        return p[0] >= self.x and p[0] <= self.x + self.w and
            p[1] >= self.y and p[1] <= self.y + self.h;
    }

    /// Inside the rect AND inside its rounded corners.
    pub fn containsRounded(self: Rect, radius: f32, p: [2]f32) bool {
        if (!self.contains(p)) return false;
        const r = @min(radius, @min(self.w, self.h) * 0.5);
        if (!(r > 0)) return true;
        const cx = std.math.clamp(p[0], self.x + r, self.x + self.w - r);
        const cy = std.math.clamp(p[1], self.y + r, self.y + self.h - r);
        const dx = p[0] - cx;
        const dy = p[1] - cy;
        return dx * dx + dy * dy <= r * r;
    }

    /// Overlap of two rects. Empty when they miss entirely, which is the only thing
    /// clipping needs to know: an empty clip draws nothing.
    pub fn intersect(self: Rect, o: Rect) Rect {
        const x0 = @max(self.x, o.x);
        const y0 = @max(self.y, o.y);
        const x1 = @min(self.x + self.w, o.x + o.w);
        const y1 = @min(self.y + self.h, o.y + o.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    /// Exact geometry match, for identity questions.
    pub fn eql(self: Rect, o: Rect) bool {
        return self.x == o.x and self.y == o.y and self.w == o.w and self.h == o.h;
    }

    /// Stands in for "no clip". Finite on purpose: infinities make the intersection
    /// arithmetic produce NaN, and NaN survives clamping.
    pub const unbounded: Rect = .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };
};

/// A piece of screen geometry: the rect something occupies, plus the clip that was in force
/// there.
pub const Region = struct {
    rect: Rect,
    clip: Rect,
    /// identity carried from the hit that produced it, so the pressed visual can follow a
    /// keyed element through a reorder.
    key: ?u64 = null,
    /// The element's corner radius, carried so hover resolution and hit testing ask the
    /// same question the fill answered: does this shape cover the point?
    radius: f32 = 0,
    /// false = present but inert: it still occludes what is behind it, and it never becomes
    /// a hover or press candidate.
    active: bool = true,

    /// Carried so the hover scan can answer both "what lights up" and "what explains
    /// itself" from ONE traversal.
    tooltip: ?[]const u8 = null,

    pub fn eql(self: Region, rect: Rect, clip: Rect) bool {
        return self.rect.eql(rect) and self.clip.eql(clip);
    }

    pub fn holds(self: Region, p: [2]f32) bool {
        return self.rect.containsRounded(self.radius, p) and self.clip.contains(p);
    }
};

/// Renderer-agnostic draw commands. A backend either rasterises these directly (software)
/// or feeds them to a GPU pipeline (triangles + glyph quads).
pub const Halo = struct {
    color: Color,
    /// How far the ramp runs, in pixels, straddling the silhouette: fully opaque `blur / 2`
    /// inside the edge, gone `blur / 2` outside.
    blur: f32 = 12,
    /// Pixels the silhouette is pushed outward before the ramp starts. Without it a blurred
    /// shadow of a filled shape is barely visible.
    spread: f32 = 0,
    offset: [2]f32 = .{ 0, 0 },
    /// Degrees the light comes FROM, on the same clock face as a gradient's `dir`:
    /// clockwise from 12 o'clock, so `0` is overhead, `90` to the right.
    light: ?f32 = null,
    mode: Mode = .glow,
    /// How the halo is computed.
    quality: Quality = .baked,

    /// A shadow as a picture, with the two axes wired consistently: the offset is derived
    /// from the light rather than set beside it.
    pub fn shadow(color: Color, light_deg: f32, dist: f32) Halo {
        const a = light_deg * std.math.pi / 180.0;
        return .{
            .color = color,
            .mode = .outer_glow,
            .light = light_deg,
            // Away from the source, in screen pixels (y grows downward). At
            // clock 0 the lamp is above, so the shadow falls to +y.
            .offset = .{ -@sin(a) * dist, @cos(a) * dist },
            .blur = 18,
            .spread = 2,
        };
    }

    pub const Mode = enum { glow, outer_glow, inner_glow };
    pub const Quality = enum { baked, sdf };
};

/// Frost a backdrop: what is already drawn under the element, blurred, before the element
/// paints itself.
pub const Frost = struct {
    /// How far the blur reaches, in pixels. A radius, not a sigma: the passes are sized
    /// from it, and doubling it visibly doubles the smear.
    blur: f32 = 12,
};

pub const Primitive = union(enum) {
    quad: struct { rect: Rect, fill: Fill, clip: Rect },
    /// rounded rect: `stroke` draws a 1px outline instead of a fill
    rrect: struct { rect: Rect, radius: f32, fill: Fill, stroke: ?u8, clip: Rect },
    /// `face` selects a registered typeface by index, 0 being the primary. Behind the
    /// scenes on purpose: a `view` never writes this.
    text: struct {
        x: f32,
        y: f32,
        size: f32,
        fill: Fill,
        bytes: []const u8,
        clip: Rect,
        face: u16 = 0,
        weight: u16 = 0,
        stroke: ?u8 = null,
        /// Glyph outline width when `.border` is set on text; null means no
        /// glyph border. Carried beside `stroke` because the two are different
        /// paints: a stroke REPLACES the fill and leaves the interior hollow,
        /// a border runs outside the ink so the fill still shows inside it.
        border: ?u8 = null,
        /// Colour of the glyph border, separate from the fill it encloses.
        border_fill: ?Fill = null,
        /// A glow traced around the GLYPH OUTLINES, drawn before the fill so it
        /// sits behind the letters. The same `.halo` a theme writes for any
        /// element: on TEXT it follows the contours instead of the box.
        text_halo: ?Halo = null,
    },
    /// Recorded where it has to composite: before the element's own fill for `glow` and
    /// `shadow`, after it for `inner_glow`.
    halo: struct { rect: Rect, corner: f32, halo: Halo, clip: Rect },
    /// Blurs what is already on the canvas under `rect`. A backdrop effect, so it is
    /// recorded BEFORE the element's fill and reads the destination.
    frost: struct { rect: Rect, radius: f32, blur: f32, clip: Rect },
    /// A provider's pixels. BORROWED, and the borrow is the whole contract:
    /// the slice is whatever the caller handed `Renderer.blit`, it must outlive
    /// the frame that recorded it, and nothing here copies or frees it.
    blit: struct { rect: Rect, pixels: []const u8, src_w: u32, src_h: u32, clip: Rect },

    /// An SVG to rasterise INTO the target. The SOURCE is recorded, not pixels:
    /// the renderer owns a cache keyed on (path, size, density, colour) and
    /// reads each file once, so recording a raster here would throw that away
    /// and re-rasterise per frame -- the cost the cache exists to remove.
    icon: struct { rect: Rect, path: []const u8, col: [3]u8, clip: Rect },

    /// A raster image to draw. SOURCE, not pixels, for the same reason `icon`
    /// records a path: the renderer owns a pixel cache keyed on the path and
    /// reads each file once.
    image: struct { rect: Rect, path: []const u8, fit: ImageFit, clip: Rect },

    /// `clip` is repeated in each prong because a Zig union has no common fields.
    pub fn clipOf(self: Primitive) Rect {
        return switch (self) {
            .quad => |q| q.clip,
            .rrect => |q| q.clip,
            .text => |t| t.clip,
            .halo => |h| h.clip,
            .frost => |f| f.clip,
            .blit => |b| b.clip,
            .icon => |i| i.clip,
            .image => |i| i.clip,
        };
    }
};

// ---------------------------------------------------------------------------
// renderer interface — a vtable, since Zig has no trait objects
// ---------------------------------------------------------------------------

/// Metrics for one line of text. `line_height` includes the font's line gap, so N lines
/// occupy `height + (N - 1) * line_height`.
pub const max_lines: usize = 32;

/// What a measurement reports.
pub const Extent = struct {
    /// width taken at the avail_w this was measured with
    w: f32 = 0,
    /// height at that width
    h: f32 = 0,
    /// narrowest width that still preserves the content
    min_w: f32 = 0,
};

/// The widest unbreakable run in `bytes`, which is the floor for wrapped text.
pub fn longestWord(r: Renderer, bytes: []const u8, size: f32) f32 {
    var best: f32 = 0;
    var it = std.mem.tokenizeAny(u8, bytes, " \n\t");
    while (it.next()) |word| {
        const w = r.measureText(word, size).width;
        if (w > best) best = w;
    }
    return best;
}

/// A flat colour as a fill. Free function because `Fill.solid` is already a union member,
/// so a method of the same name cannot exist.
pub fn solid(c: Color) Fill {
    return .{ .solid = c };
}

/// How wide a row child ends up when the row cannot give everyone what they asked for.
pub fn rowChildWidth(c: Extent, total_w: f32, total_min: f32, inner: f32) f32 {
    if (total_w <= inner) return c.w;
    const slack = c.w - c.min_w;
    const room = total_w - total_min;
    if (room <= 0) return c.min_w;
    const deficit = total_w - inner;
    if (deficit >= room) return c.min_w;
    return c.w - deficit * (slack / room);
}

/// Cross-axis placement for a row's children.
pub const RowAlign = enum { stretch, start, center, baseline };

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
    line_height: f32,
};

pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Fill an outline.
    pub fn path(self: Renderer, x: f32, y: f32, p: Path, fill: Fill, clip: Rect) void {
        self.vtable.path(self.ptr, x, y, p, fill, clip);
    }

    pub const VTable = struct {
        quad: *const fn (ptr: *anyopaque, rect: Rect, fill: Fill, clip: Rect) void,
        /// draws a rounded rect, or its outline of `stroke` pixels when set
        rrect: *const fn (ptr: *anyopaque, rect: Rect, radius: f32, fill: Fill, stroke: ?u8, clip: Rect) void,
        text: *const fn (ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void,
        /// Text drawn as an OUTLINE of the glyphs, not a fill. A backend with no
        /// distance-field support falls back to `text`.
        stroked_text: *const fn (ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, width: u8, clip: Rect, kind: u8) void,
        /// A glow around the GLYPH OUTLINES. Drawn before the fill, so it
        /// composites behind the letters rather than washing over them.
        text_halo: *const fn (ptr: *anyopaque, x: f32, y: f32, size: f32, h: Halo, bytes: []const u8, clip: Rect) void,
        /// Point subsequent `text` calls at a registered face, by index. 0 is the primary.
        /// A backend with only one face ignores it.
        set_face: *const fn (ptr: *anyopaque, face: u16) void,
        /// `wght` for the face `set_face` last named, or 0 for its default instance.
        set_weight: *const fn (ptr: *anyopaque, weight: u16) void,
        /// A glow or shadow behind `rect`. `corner` is the element's own radius so the halo
        /// follows its shape rather than boxing it.
        halo: *const fn (ptr: *anyopaque, rect: Rect, corner: f32, h: Halo, clip: Rect) void,
        /// Blurs the destination under `rect`, in place. Must be called BEFORE the element
        /// draws, or it frosts the element too.
        frost: *const fn (ptr: *anyopaque, rect: Rect, radius: f32, blur: f32, clip: Rect) void,
        measure_text: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32) TextMetrics,
        /// Metrics for a string measured ON `face` -- the same face its glyphs will be
        /// drawn with.
        measure_text_face: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32, face: u16) TextMetrics,
        /// Splits into lines no wider than `max_width`. Returns the count.
        wrap_text: *const fn (
            ptr: *anyopaque,
            bytes: []const u8,
            size: f32,
            max_width: f32,
            out: [][]const u8,
        ) usize,
        /// Width of `bytes[0..index]`: where a caret before that byte sits.
        advance_text: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32, index: usize) f32,
        /// The byte boundary nearest `x`: what a click selects.
        hit_text: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32, x: f32) usize,
        /// Fills a closed outline at (x, y).
        path: *const fn (ptr: *anyopaque, x: f32, y: f32, p: Path, fill: Fill, clip: Rect) void,
        /// Draws a straight-alpha RGBA8 buffer into `rect`, scaling it to fit.
        /// `pixels.len` must be `src_w * src_h * 4`; a short or empty buffer is
        /// ignored rather than reading past the end.
        ///
        /// No scaling filter is promised: a backend may sample the nearest
        /// source pixel, and an icon drawn at its natural size -- which is what
        /// a provider should hand over -- never needs more.
        blit: *const fn (
            ptr: *anyopaque,
            rect: Rect,
            pixels: []const u8,
            src_w: u32,
            src_h: u32,
            clip: Rect,
        ) void,

        /// Draw the SVG file at `path` into `rect`, rasterised to fit at the
        /// current density and tinted `col`.
        ///
        /// Separate from `blit` rather than a variant of it: `blit` takes
        /// finished pixels and cannot cache, because it cannot tell two sources
        /// apart. This one can, so the renderer reads and parses each file once
        /// per (path, size, density, colour) instead of once per frame.
        ///
        /// A backend with no SVG support omits it and gets nothing drawn --
        /// the same contract as any other optional capability here.
        /// Intrinsic size of the image at `path`, or null if it cannot be
        /// read. Header only, never a decode: this is called from `measure`,
        /// and layout must not depend on whether a pixel cache happens to be
        /// warm. That is precisely what keeps a miss from changing layout.
        measure_image: *const fn (ptr: *anyopaque, path: []const u8) ?[2]u32,

        /// How an image fills the box it was given. `.fit` letterboxes (keeps
        /// the source aspect, centres, leaves the box alone); `.stretch` fills
        /// it exactly.
        blit_image: *const fn (
            ptr: *anyopaque,
            rect: Rect,
            path: []const u8,
            fit: ImageFit,
            clip: Rect,
        ) void,

        blit_svg: *const fn (
            ptr: *anyopaque,
            rect: Rect,
            path: []const u8,
            col: [3]u8,
            clip: Rect,
        ) void,
    };

    /// `clip` is required, not defaulted: every draw call names the rect it is confined to.
    pub fn quad(self: Renderer, rect: Rect, fill: Fill, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        self.vtable.quad(self.ptr, rect, fill, clip);
    }

    /// Draw a provider's pixels into `rect`. The size check lives here so every
    /// backend inherits it: a caller that passes a mismatched buffer is a bug in
    /// the widget, not something each backend should rediscover.
    pub fn blit(
        self: Renderer,
        rect: Rect,
        pixels: []const u8,
        src_w: u32,
        src_h: u32,
        clip: Rect,
    ) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        if (src_w == 0 or src_h == 0) return;
        const need = @as(usize, src_w) * @as(usize, src_h) * 4;
        if (pixels.len < need) return;
        const c = clip.intersect(rect);
        if (c.isEmpty()) return;
        self.vtable.blit(self.ptr, rect, pixels[0..need], src_w, src_h, c);
    }

    /// Draw the SVG at `path` into `rect`, tinted `col`. The backend reads and
    /// rasterises it ONCE per (path, size, density, colour) and reuses the
    /// result, so a caller may call this every frame.
    ///
    /// The emptiness check is here for the same reason `blit`'s buffer check is:
    /// a degenerate rect or an empty path is the widget's bug, not something
    /// each backend should rediscover.
    pub fn blitSvg(self: Renderer, rect: Rect, svg_path: []const u8, col: [3]u8, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        if (svg_path.len == 0) return;
        const c = clip.intersect(rect);
        if (c.isEmpty()) return;
        self.vtable.blit_svg(self.ptr, rect, svg_path, col, c);
    }

    pub fn roundedRect(self: Renderer, rect: Rect, radius: f32, fill: Fill, stroke: ?u8, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        self.vtable.rrect(self.ptr, rect, radius, fill, stroke, clip);
    }

    pub fn text(self: Renderer, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void {
        if (bytes.len == 0) return;
        self.vtable.text(self.ptr, x, y, size, fill, bytes, clip);
    }

    /// Text whose glyphs are outlined rather than filled.
    /// Glyphs outlined in `fill`, with the interior left to a fill drawn
    /// afterwards. `.stroke` is the hollow alternative.
    pub fn borderedText(self: Renderer, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, width: u8, clip: Rect) void {
        self.vtable.stroked_text(self.ptr, x, y, size, fill, bytes, width, clip, 1);
    }

    pub fn strokedText(self: Renderer, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, width: u8, clip: Rect) void {
        // kind 0 = stroke (hollow), 1 = border (filled inside).

        if (bytes.len == 0) return;
        self.vtable.stroked_text(self.ptr, x, y, size, fill, bytes, width, clip, 0);
    }

    /// A glow traced around the glyphs themselves, not round a box.
    pub fn textHalo(self: Renderer, x: f32, y: f32, size: f32, h: Halo, bytes: []const u8, clip: Rect) void {
        if (bytes.len == 0) return;
        // A glyph halo has no box, but it does have a signed distance field, so
        // `mode`, `spread` and `offset` all apply: the same ramp runs on either
        // side of the contour, pushed off it by `spread` and slid by `offset`.
        if (h.color.a == 0 or h.blur <= 0) return;
        self.vtable.text_halo(self.ptr, x, y, size, h, bytes, clip);
    }

    /// Point subsequent `text` calls at a registered face, by index.
    pub fn setFace(self: Renderer, face: u16) void {
        self.vtable.set_face(self.ptr, face);
    }

    /// Text in a registered face, by index. The face is STICKY rather than an argument to
    /// every draw.
    pub fn setWeight(self: Renderer, weight: u16) void {
        self.vtable.set_weight(self.ptr, weight);
    }

    pub fn textFace(self: Renderer, face: u16, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void {
        if (bytes.len == 0) return;
        if (face != 0) self.vtable.set_face(self.ptr, face);
        self.vtable.text(self.ptr, x, y, size, fill, bytes, clip);
    }

    /// A glow or shadow, drawn where the caller asked for it.
    pub fn halo(self: Renderer, rect: Rect, corner: f32, h: Halo, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        if (h.color.a == 0) return;
        self.vtable.halo(self.ptr, rect, corner, h, clip);
    }

    /// Frost the backdrop under `rect`.
    pub fn frost(self: Renderer, rect: Rect, radius: f32, blur: f32, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0 or blur <= 0) return;
        self.vtable.frost(self.ptr, rect, radius, blur, clip);
    }

    pub fn measureText(self: Renderer, bytes: []const u8, size: f32) TextMetrics {
        return self.vtable.measure_text(self.ptr, bytes, size);
    }

    /// Draw the raster image at `src` into `rect`. See `VTable.blit_image`.
    pub fn blitImage(self: Renderer, rect: Rect, src: []const u8, fit: ImageFit, clip: Rect) void {
        self.vtable.blit_image(self.ptr, rect, src, fit, clip);
    }

    /// Intrinsic size of an image for layout. See `VTable.measure_image`.
    /// `src` rather than `path`: `Renderer.path` is the outline call, and a
    /// parameter of that name shadows it.
    pub fn imageSize(self: Renderer, src: []const u8) ?[2]u32 {
        return self.vtable.measure_image(self.ptr, src);
    }

    /// Metrics on the face `bytes` will actually be DRAWN with.
    pub fn measureTextFace(self: Renderer, bytes: []const u8, size: f32, face: u16) TextMetrics {
        return self.vtable.measure_text_face(self.ptr, bytes, size, face);
    }

    pub fn wrapText(self: Renderer, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
        return self.vtable.wrap_text(self.ptr, bytes, size, max_width, out);
    }

    /// Width of the first `index` bytes.
    pub fn advanceText(self: Renderer, bytes: []const u8, size: f32, index: usize) f32 {
        if (bytes.len == 0) return 0;
        return self.vtable.advance_text(self.ptr, bytes, size, @min(index, bytes.len));
    }

    /// The byte boundary under `x`. Single line only: resolving y to a line is the
    /// caller's, because only it knows how the text was wrapped.
    pub fn hitText(self: Renderer, bytes: []const u8, size: f32, x: f32) usize {
        if (bytes.len == 0) return 0;
        return self.vtable.hit_text(self.ptr, bytes, size, x);
    }
};

/// How a self-intersecting outline decides what is inside it.
pub const FillRule = enum { nonzero, evenodd };

pub const PathOp = enum { move, line, quad, cubic, close };

/// An outline in the caller's own coordinates. Curves stay curves.
pub const Path = struct {
    ops: []const PathOp,
    /// One point per `move`/`line`, two per `quad` (control then end), three per `cubic`
    /// (two controls then end), none for `close`.
    points: []const [2]f32,
    rule: FillRule = .nonzero,
};

/// Zig 0.17 split `Struct.fields` into parallel arrays and dropped
/// StructField. This rebuilds a {name, type} view for `inline for`.
pub const StructField = struct {
    name: [:0]const u8,
    type: type,
};

pub fn structFields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]StructField {
    const info = @typeInfo(T).@"struct";
    var out: [info.field_names.len]StructField = undefined;
    inline for (info.field_names, info.field_types, 0..) |n, t, i| {
        out[i] = .{ .name = n, .type = t };
    }
    return out;
}
