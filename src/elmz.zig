//! elmz — an Elm / iced shaped GUI runtime for Zig 0.16+.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// geometry / color
// ---------------------------------------------------------------------------

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
fn longestWord(r: Renderer, bytes: []const u8, size: f32) f32 {
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
fn rowChildWidth(c: Extent, total_w: f32, total_min: f32, inner: f32) f32 {
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

// ---------------------------------------------------------------------------
// element tree
// ---------------------------------------------------------------------------

/// The palette a `Ui` builds with.
pub const Theme = struct {
    /// page/window background; the colour a backend clears to
    bg: Color = Color.rgbHex(0x1e1e2e),
    /// raised fill: panels, cards, rows
    panel: Color = Color.rgbHex(0x313244),
    /// outlines and dividers
    border: Color = Color.rgbHex(0x9399b2),
    /// primary text
    text: Color = Color.rgbHex(0xcdd6f4),
    /// secondary text: captions, hints, units
    text_muted: Color = Color.rgbHex(0xa6adc8),
    /// control fill at rest
    control: Color = Color.rgbHex(0x45475a),
    /// control fill under the pointer
    hover: Color = Color.rgbHex(0x6c7086),
    /// control fill while that control owns the press
    pressed: Color = Color.rgbHex(0x7f849c),
    /// this item is the chosen one among its peers
    selected: Color = Color.rgbHex(0x585b70),
    /// emphasis: active borders, markers, value fills
    accent: Color = Color.rgbHex(0x89b4fa),
    /// a thing worked: a success toast's bar, a passing check
    success: Color = Color.rgbHex(0xa6e3a1),
    /// a thing still works but wants attention: a warning toast's bar
    warning: Color = Color.rgbHex(0xf9e2af),
    /// a thing failed: the error band's text, an error toast's bar
    fail: Color = Color.rgbHex(0xf38ba8),

    /// Colours the theme file defined beyond the built-ins.
    custom: []const CustomColor = &.{},

    pub const CustomColor = struct { name: []const u8, color: Color };

    /// Look up a custom role. Null when the name is not one.
    pub fn customColor(self: Theme, name: []const u8) ?Color {
        for (self.custom) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.color;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// theme files: a flat .zon becomes a Theme
// ---------------------------------------------------------------------------

/// The theme machinery -- spec, loader, diagnostics, palette guard -- lives in `theme.zig`.
pub const theme = @import("theme.zig");
pub const RoleFamily = theme.RoleFamily;
pub const ThemeSpec = theme.ThemeSpec;
pub const Gradients = theme.Gradients;
pub const GradientSpec = theme.GradientSpec;
pub const ThemeFileType = theme.ThemeFileType;
pub const Loaded = theme.Loaded;
pub const ThemeDiag = theme.ThemeDiag;
pub const font_name_max = theme.font_name_max;
pub const ThemeLoadError = theme.ThemeLoadError;
pub const theme_version = theme.theme_version;
pub const defaults_zon = theme.defaults_zon;
pub const loadTheme = theme.loadTheme;
pub const checkPalette = theme.checkPalette;

test {
    // A sibling file's tests only join this module's binary once something
    // pulls its declarations in. The aliases above are what a caller uses; this
    // is what makes the suite see them.
    std.testing.refAllDecls(theme);
}

/// The failure banner is deliberately not themed: it reports a bug, so it must not be able
/// to blend into whatever palette the app chose.
const band_h: f32 = 20;
const band_bg: Color = Color.rgbHex(0xd0342c);
const band_fg: Color = Color.rgbHex(0xfff2f0);

/// Why a frame drew its error band.
pub const FailKind = enum {
    /// an allocation inside `view` failed; the tree is structurally degraded
    layout_allocation,
    /// two hit regions declared the same `key`, so identity is ambiguous
    duplicate_key,
    /// the typeface the app asked for could not be read; the band carries the path.
    font,
    /// the theme file could not be parsed or resolved; the detail in the band carries the
    /// file, line and column.
    theme,
    /// a style NAME was looked up and the theme has no such style. Reported rather than
    /// silently defaulting: an unknown name paints the compiled floor with no error,
    /// which is indistinguishable from a typo that "worked".
    style,

    /// The fallback text, used when the failure carries no detail. Callers that know more
    /// call `Ui.failFmt` and get the detail appended instead.
    pub fn message(self: FailKind) []const u8 {
        return switch (self) {
            .layout_allocation => "render failed: layout allocation",
            .duplicate_key => "render failed: duplicate key",
            .theme => "render failed: theme",
            .style => "render failed: unknown style",
            .font => "render failed: font",
        };
    }
};

/// What the wheel needs from a scroll viewport: how tall the content is and how much of it
/// is on screen.
pub const ScrollView = struct {
    content_h: f32,
    view_h: f32,
    /// The other axis. A container can overflow both ways at once, and the wheel needs both
    /// extents to know which delta to spend.
    content_w: f32 = 0,
    view_w: f32 = 0,
};

/// A request to move one viewport. Two forms because the two things an app actually wants
/// are different: go to a place, or move by an amount.
pub const ScrollChange = union(enum) {
    to: struct { key: u64, offset: f32 },
    by: struct { key: u64, dy: f32 },
};

/// The named colours a theme need not declare. CSS's base 16 plus the few every
/// dialect adds, because `.color = .red` should work the way it does everywhere else.
///
/// `transparent` is here rather than in CSS's own list because a theme has no other
/// way to spell it, and `Color.a` defaults to 255 so a solid is the only thing a hex
/// can express.
pub fn builtinColor(name: []const u8) ?Color {
    const list = .{
        .{ "black", 0x000000 },   .{ "white", 0xffffff },
        .{ "gray", 0x808080 },    .{ "grey", 0x808080 },
        .{ "silver", 0xc0c0c0 },  .{ "maroon", 0x800000 },
        .{ "red", 0xff0000 },     .{ "purple", 0x800080 },
        .{ "fuchsia", 0xff00ff }, .{ "green", 0x008000 },
        .{ "lime", 0x00ff00 },    .{ "olive", 0x808000 },
        .{ "yellow", 0xffff00 },  .{ "navy", 0x000080 },
        .{ "blue", 0x0000ff },    .{ "teal", 0x008080 },
        .{ "aqua", 0x00ffff },    .{ "cyan", 0x00ffff },
        .{ "magenta", 0xff00ff }, .{ "orange", 0xffa500 },
    };
    inline for (list) |e| {
        if (std.mem.eql(u8, name, e[0])) return Color.rgbHex(e[1]);
    }
    // Alphabetic aliases of the same thing, kept out of the table above so the
    // canonical spelling stays first in it.
    if (std.mem.eql(u8, name, "transparent")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return null;
}

/// One viewport's offset, keyed by the element's `key`.
pub fn roleColor(pal: Theme, name: []const u8) Color {
    // Custom FIRST, and the order is load-bearing: a file that writes
    // `.roles = .{ .{ .name = "bg", ... } }` is retuning a built-in, and with
    // the built-ins checked first that entry could never win -- the file would
    // look ignored rather than wrong. A duplicate NAME is a parse error, so
    // there is no ambiguity to resolve here, only precedence to get right.
    if (pal.customColor(name)) |c| return c;
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        if (comptime !std.mem.eql(u8, f.name, "custom")) {
            if (std.mem.eql(u8, name, f.name)) return @field(pal, f.name);
        }
    }
    // THEN the built-ins, and only after the file's own names. A theme that
    // happens to declare `.red = 0xff0088` must keep it, so this can never run
    // first; and a genuinely misspelled role is likelier to be a colour someone
    // reached for than a name the theme forgot.
    if (builtinColor(name)) |c| return c;

    // A name the file defined beats the `text` fallback. Without this a custom
    // role resolved to `text` -- a real colour, so nothing looked broken, the
    // label just drew in the wrong one.
    return pal.text;
}

/// A halo as a DOCUMENT sees it: the colour is a role name, everything else is a number.
pub const HaloSpecEntry = struct {
    color: []const u8 = "text_muted",
    blur: f32 = 12,
    spread: f32 = 0,
    offset: [2]f32 = .{ 0, 0 },
    light: ?f32 = null,
    mode: Halo.Mode = .glow,
    quality: Halo.Quality = .baked,
};

/// A theme style as a VIEW sees it.
pub const StyleEntry = struct {
    name: []const u8,
    spec: struct {
        bg: ?[]const u8 = null,
        color: ?[]const u8 = null,
        border: ?[]const u8 = null,
        /// Border width in pixels; absent means 1.
        border_width: ?f32 = null,
        font: ?[]const u8 = null,
        /// Point size named by the theme.
        size: ?f32 = null,
        /// Weight in the variable `wght` axis, in user units (400, 700).
        weight: ?u16 = null,
        /// A glow or shadow, with its colour named as a theme role so it follows `.colors`
        /// instead of freezing a hex.
        halo: ?HaloSpecEntry = null,
        /// Blur of what is behind this element, from a theme style.
        frost: ?FrostSpecEntry = null,
        /// Outline width in pixels; absent fills solid.
        stroke: ?u8 = null,
    } = .{},
};

/// Frost as a theme file writes it.
pub const FrostSpecEntry = struct {
    blur: f32 = 12,
};

/// The styles every Ui has before any theme file is read.
pub const default_styles: []const StyleEntry = &.{
    .{ .name = "latin", .spec = .{ .color = "text", .font = "Roboto Flex" } },
    .{ .name = "arabic", .spec = .{ .color = "text", .font = "Noto Sans Arabic" } },
    .{ .name = "thai", .spec = .{ .color = "text", .font = "Noto Sans Thai" } },
    .{ .name = "chinese", .spec = .{ .color = "text", .font = "Noto Sans CJK SC" } },
    .{ .name = "japanese", .spec = .{ .color = "text", .font = "Noto Sans CJK JP" } },
    .{ .name = "korean", .spec = .{ .color = "text", .font = "Noto Sans CJK KR" } },
    // `latin` above carries no weight on purpose: omitted means "whatever the
    // face says", so a replacement face is not forced to a weight nobody chose.
    .{ .name = "heading", .spec = .{ .color = "text", .font = "Roboto Flex", .size = 34, .weight = 800 } },
    .{ .name = "card", .spec = .{
        .bg = "panel",
        .border = "border",
        .halo = .{ .color = "bg", .blur = 10, .offset = .{ 0, 6 }, .mode = .outer_glow },
    } },
};

pub const FaceLookup = struct {
    ptr: *const anyopaque,
    resolve: *const fn (ptr: *const anyopaque, name: []const u8) ?u16,
};

pub const ScrollSlot = struct { key: u64 = 0, offset: f32 = 0, offset_x: f32 = 0 };

/// Scrollbar geometry, in logical units.
pub const scrollbar_w: f32 = 6;
pub const scrollbar_min_thumb: f32 = 24;
/// How wide the thumb's claim on the pointer is. Deliberately wider than the strip it
/// paints: a 6px target is not grabbable.
pub const scrollbar_grab: f32 = 14;

/// The root container's scroll identity. Any constant works -- what matters is that it is
/// stable across frames, because the scroll store outlives one.
pub const scroll_path_root: u64 = 0x9e3779b97f4a7c15;

/// One step down the tree.
pub fn fieldOr(o: anytype, comptime name: []const u8, comptime default: anytype) FieldType(@TypeOf(o), name, @TypeOf(default)) {
    // Comptime-gated on the whole body: when the struct has the field, its
    // value is coerced to the destination type; when it does not, the default
    // stands. Both arms have to be legal for the type that is actually
    // returned, so neither may be written unconditionally.
    if (comptime !@hasField(@TypeOf(o), name)) return default;
    const R = FieldType(@TypeOf(o), name, @TypeOf(default));
    // A typed local, not `@as`: coercing an anonymous struct literal to a named
    // struct is assignment, and `@as` refuses it.
    const r: R = @field(o, name);
    return r;
}

fn isOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

/// The field's own type when the struct has it, so an anonymous struct literal passed as
/// `.style = .{ ... }` still coerces.
pub fn FieldType(comptime O: type, comptime name: []const u8, comptime Fallback: type) type {
    if (!@hasField(O, name)) return Fallback;
    const F = @FieldType(O, name);
    return switch (@typeInfo(F)) {
        // `.size = 12` infers `comptime_int`, which is comptime-only: a
        // function cannot return it. The declared default's type is what the
        // caller meant by passing a bare number.
        .comptime_int, .comptime_float => Fallback,
        // A caller who writes `.style = .{ .bg = c }` has an anonymous struct
        // type that is not expressible outside that expression. Comparing it
        // to anything is unreliable, so a struct-valued field always resolves
        // to the declared default's type -- which is the destination.
        .@"struct" => Fallback,
        else => F,
    };
}

pub fn pathChild(parent: u64, index: usize) u64 {
    var h = parent ^ 0xcbf29ce484222325;
    h *%= 0x100000001b3;
    h ^= @as(u64, @intCast(index)) +% 1;
    h *%= 0x100000001b3;
    return h;
}

/// A thumb that has taken the pointer.
pub const ScrollDrag = struct {
    key: u64,
    view: ScrollView,
    /// Which offset this thumb writes.
    horizontal: bool = false,
};

/// Which way a control runs.
pub const Orientation = enum { horizontal, vertical };

/// A slider that has taken the pointer.
pub const SliderDrag = struct {
    key: u64,
    /// The track as laid out in the frame the press happened in.
    rect: Rect,
    /// Into the Model, never the arena: a drag outlives the frame that began it.
    value: *f32,
    min: f32,
    max: f32,
    /// null = continuous.
    step: ?f32,
    orientation: Orientation,
};

/// What has taken the pointer for continuous motion.
pub const Drag = union(enum) {
    thumb: ScrollDrag,
    slider: SliderDrag,
};

/// Where a pointer sits across a slider's range, 0..1.
fn sliderFraction(rect: Rect, orientation: Orientation, p: [2]f32) f32 {
    const t = switch (orientation) {
        .horizontal => if (rect.w > 0) (p[0] - rect.x) / rect.w else 0,
        .vertical => if (rect.h > 0) (rect.y + rect.h - p[1]) / rect.h else 0,
    };
    return std.math.clamp(t, 0, 1);
}

/// The value under the pointer, quantised to the grid when there is one.
pub fn sliderValueAt(d: SliderDrag, p: [2]f32) f32 {
    return quantise(d, d.min + sliderFraction(d.rect, d.orientation, p) * (d.max - d.min));
}

/// One step TOWARD the pointer, never to it.
pub fn sliderStepToward(d: SliderDrag, current: f32, p: [2]f32) f32 {
    const target = sliderValueAt(d, p);
    const step = d.step orelse return target;
    if (target > current) return @min(current + step, target);
    if (target < current) return @max(current - step, target);
    return current;
}

fn quantise(d: SliderDrag, raw: f32) f32 {
    const clamped = std.math.clamp(raw, d.min, d.max);
    const step = d.step orelse return clamped;
    if (step <= 0) return clamped;
    return std.math.clamp(d.min + @round((clamped - d.min) / step) * step, d.min, d.max);
}

/// What a toast is telling the app.
pub const Severity = enum { info, success, warning, @"error" };

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

/// Where a popup sits relative to the anchor it belongs to. Same box either way; the
/// difference is which edge stays put.
pub const PopupAnchor = enum {
    /// A control that expanded: grow evenly above and below, centred on the field.
    centred,
    /// A command that drops out of its trigger.
    below,
};

/// Rows past this scroll inside a fixed-height box.
pub const popup_max_rows: usize = 5;

/// One row's height.
pub const popup_row_h: f32 = 26;

pub const PopupLayout = struct {
    rect: Rect,
    /// Index of the first row painted.
    first: usize,
    count: usize,
};

/// The box a popup occupies, and which rows of a long list it shows.
pub fn popupLayout(
    anchor: Rect,
    widest: f32,
    rows: usize,
    active: ?usize,
    view: Size,
    mode: PopupAnchor,
    row_h: f32,
) PopupLayout {
    if (rows == 0) {
        return .{ .rect = .{ .x = anchor.x, .y = anchor.y, .w = 0, .h = 0 }, .first = 0, .count = 0 };
    }
    const count = @min(rows, popup_max_rows);
    // Wide enough that the closed control never reflows when the list opens,
    // and capped to the viewport so one absurd option cannot push it off.
    const w = @min(@max(anchor.w, widest), view.w);
    const h = @as(f32, @floatFromInt(count)) * row_h;

    var first: usize = 0;
    if (active) |a| {
        const half = (count - 1) / 2;
        first = if (a > half) a - half else 0;
        if (first + count > rows) first = rows - count;
    }

    const x = switch (mode) {
        .centred => std.math.clamp(anchor.x + anchor.w / 2 - w / 2, 0, @max(0, view.w - w)),
        // Clamped at BOTH ends. Only shifting on right overflow left an
        // anchor at a negative x hanging its menu off the left edge -- the
        // centred branch clamped, and this one quietly did not.
        .below => std.math.clamp(anchor.x, 0, @max(0, view.w - w)),
    };
    const y = switch (mode) {
        .centred => std.math.clamp(anchor.y + anchor.h / 2 - h / 2, 0, @max(0, view.h - h)),
        .below => blk: {
            const under = anchor.y + anchor.h;
            if (under + h <= view.h) break :blk under;
            break :blk @max(0, anchor.y - h);
        },
    };

    return .{ .rect = .{ .x = x, .y = y, .w = w, .h = h }, .first = first, .count = count };
}

/// One row of a select, menu or list.
pub fn Choice(comptime M: type) type {
    return struct {
        label: []const u8 = "",
        msg: ?M = null,
        disabled: bool = false,
    };
}

/// What a control must tell the runtime that the app cannot. This is the SIBLING of
/// `Geometry`, not a variant of it.
pub fn Widget(comptime M: type) type {
    return union(enum) {
        /// A value control. The runtime maps the pointer to a number and writes it through
        /// `value`, because only the runtime sees motion between frames.
        slider: struct {
            /// Into the Model, not the arena: a drag outlives the frame that started it,
            /// and app state is the one thing that does.
            value: *f32,
            min: f32 = 0,
            max: f32 = 1,
            /// null = continuous.
            step: ?f32 = null,
            orientation: Orientation = .horizontal,
            msg: M,
        },
        /// A collapsed list of options.
        select: struct {
            open: bool,
            selected: u16,
            /// A pointer into the Model so hover, arrows and typeahead write one number.
            /// Two copies would let the highlight disagree with what Enter activates.
            active: *?u16,
            options: []const Choice(M),
            /// Emitted by the closed field, to toggle.
            msg: M,
        },
        /// Commands rather than a value.
        menu: struct {
            open: bool,
            active: *?u16,
            items: []const Choice(M),
            toggle: M,
        },
        /// A notification.
        toast: struct {
            severity: Severity = .info,
            ttl_ms: u32 = 4000,
            /// Emitted on expiry or on click.
            msg: M,
        },
        /// A text field.
        input: struct {
            edit: *reducer.TextEdit,
            /// What is DRAWN and MEASURED.
            display: []const u8,
            size: f32 = 14,
            /// Masks imply single line: a wrapped password is not a thing.
            mask: bool = false,
            placeholder: []const u8 = "",
            /// The field's inner inset.
            pad: f32 = 6,
            /// Emitted when the runtime moves the caret (a click).
            msg: ?M = null,
            /// Whether this field scrolls its own contents. Set by the builder
            /// for a box whose content can exceed it; layout then gives the
            /// element a scroll key so the ordinary implicit-scroll machinery
            /// -- wheel region, thumbs, bar -- applies with no extra code.
            scrolls: bool = false,
        },
    };
}

/// Draw a text field's CONTENT: the placeholder, the value, the caret.
fn paintInput(
    r: Renderer,
    th: Theme,
    ti: anytype,
    rect: Rect,
    focused: bool,
    hov: Hover,
    /// Already clamped by the caller against the content height it measured.
    /// A field that does not scroll is handed 0.
    scroll_off: f32,
    /// The field's own interior, already intersected with the inherited clip.
    /// Text and caret are confined to THIS, not to the parent's clip: a field
    /// with a fixed height overflows by construction, and drawing past its own
    /// box is the leak this replaces.
    vp: Rect,
) void {
    const pad = ti.pad;
    const ix = rect.x + pad;
    const iy = rect.y + pad;
    const iw = rect.w - 2 * pad;
    if (iw <= 0 or rect.h <= 0) return;
    const edit = ti.edit;
    const size = ti.size;

    // The bytes on screen. A masked field draws `display`, which is one `?`
    // per codepoint by construction, so the caret index has to be converted
    // into those same units: a caret placed from the real bytes would point
    // past the end of what is drawn, which is also how a password leaks its
    // length.
    const shown = ti.display;
    var caret = @min(edit.caret, shown.len);
    if (ti.mask) {
        const upto = @min(edit.caret, edit.value.len);
        caret = std.unicode.utf8CountCodepoints(edit.value[0..upto]) catch upto;
        caret = @min(caret, shown.len);
    }

    const ts = r.measureText(shown, size);
    var line_buf: [64][]const u8 = undefined;
    const nlines = r.wrapText(shown, size, iw, &line_buf);
    const lines = line_buf[0..nlines];

    // Which line the caret is on, and how far into it, by pointer difference:
    // `wrapText` hands back slices of the string it was given.
    var cline: usize = 0;
    var coff: usize = caret;
    if (lines.len > 0) {
        const base = @intFromPtr(shown.ptr);
        for (lines, 0..) |ln, i| {
            const off = @intFromPtr(ln.ptr) - base;
            if (caret >= off and caret <= off + ln.len) {
                cline = i;
                coff = caret - off;
                break;
            }
        }
    }

    // Scrolled by the SHARED offset, not a field-local one: the wheel, the bar
    // and the clamp all belong to the runtime's per-path slot, so a second
    // offset here would drift from the bar that is drawn beside it.
    const oy = iy - scroll_off;

    if (shown.len == 0) {
        if (ti.placeholder.len > 0) r.text(ix, oy, size, .{ .solid = th.text_muted }, ti.placeholder, vp);
    } else {
        for (lines, 0..) |ln, i| {
            if (ln.len == 0) continue;
            r.text(ix, oy + @as(f32, @floatFromInt(i)) * ts.line_height, size, .{ .solid = th.text }, ln, vp);
        }
    }

    if (!focused) return;
    // Not while typing: a caret that blinks mid-keystroke reads as a stutter,
    // which is what `since_input` is for.
    const blink_on = hov.since_input < 0.5 or @mod(hov.elapsed, 1.06) < 0.53;
    if (!blink_on) return;
    const line_txt = if (lines.len > 0) lines[@min(cline, lines.len - 1)] else shown[0..0];
    const pre = line_txt[0..@min(coff, line_txt.len)];
    const cx = ix + r.advanceText(pre, size, pre.len);
    const cy = oy + @as(f32, @floatFromInt(cline)) * ts.line_height;
    r.quad(.{ .x = cx, .y = cy, .w = 1, .h = @max(1, ts.line_height - 2) }, .{ .solid = th.text }, vp);
}

/// The wrapped height of what an input draws, in pixels. `paintInput` uses the
/// same `wrapText` on the same string, so the two cannot disagree about where
/// the last line sits.
fn inputContentHeight(r: Renderer, ti: anytype, iw: f32) f32 {
    const ts = r.measureText(ti.display, ti.size);
    var line_buf: [256][]const u8 = undefined;
    const n = r.wrapText(ti.display, ti.size, iw, &line_buf);
    return @as(f32, @floatFromInt(@max(n, 1))) * ts.line_height;
}

/// Where a click at pixel `x` puts the caret, as a BYTE OFFSET INTO THE VALUE.
pub fn caretAtClick(r: Renderer, ti: anytype, x: f32) usize {
    const v = ti.edit.value;
    const raw = @min(r.hitText(ti.display, ti.size, x), ti.display.len);
    var n: usize = raw; // codepoint index into the value
    if (!ti.mask) {
        // `raw` is a byte offset into the value; count the codepoints before it.
        n = 0;
        var i: usize = 0;
        while (i < raw) : (n += 1) i = reducer.nextBoundary(v, i);
    }
    var b: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) b = reducer.nextBoundary(v, b);
    return b;
}

pub fn Hit(comptime M: type) type {
    return struct {
        rect: Rect,
        clip: Rect,
        /// The message a release here dispatches, or null for a region that only routes
        /// input.
        msg: ?M = null,
        /// Set on a scroll viewport.
        scroll: ?ScrollView = null,
        /// The tree-path identity of the container that scrolled, for regions produced by
        /// IMPLICIT scrolling.
        scroll_id: ?u64 = null,
        /// Set on a scroll THUMB, which claims the pointer as a drag rather than as a
        /// press.
        drag: ?Drag = null,
        /// The focus scope this region was recorded inside, or null at the root.
        scope: ?u64 = null,
        /// Set on a row of a roving control: the control's key. Null on everything else,
        /// including the control itself.
        roving: ?u64 = null,
        roving_index: u16 = 0,
        /// Identity of the element that produced this region, if it declared one.
        key: ?u64 = null,
        /// mirrors the element's `disabled`: recorded so a press can be cancelled when the
        /// element it claimed turns inert mid-gesture.
        active: bool = true,
        /// Corner radius, so a rounded control is only claimed where it is actually painted
        /// -- its bounding box is not its shape.
        radius: f32 = 0,
        /// Whether Tab may land here. Recorded because only the frame knows document order
        /// -- an app that had to rebuild it would be reimplementing layout.
        focusable: bool = false,
        /// The control payload, if this element is a widget.
        widget: ?*const Widget(M) = null,
    };
}

/// A Hit with the borrowed widget payload removed. Everything an app can hold has to come
/// through here.
fn published(comptime M: type, h: Hit(M)) Hit(M) {
    var c = h;
    c.widget = null;
    return c;
}

/// Enqueues a hit region clipped to what is actually visible.
fn hitAppend(
    comptime M: type,
    hits: *std.ArrayList(Hit(M)),
    gpa: Allocator,
    h: Hit(M),
) Allocator.Error!void {
    if (h.rect.intersect(h.clip).isEmpty()) return;
    // A disabled element DOES enter the list, inert (`active = false`). Dropping
    // it would let a click fall through to whatever it covers, which is the one
    // thing a disabled control must never do: occlusion without claiming.
    // `Frame.hit` therefore stays a plain contains loop, and the topmost
    // containing region decides -- returning null when that region is inert
    // rather than continuing down the stack.
    try hits.append(gpa, h);
}

/// Appearance for one element, as a single value.
pub const Style = struct {
    /// Which registered typeface this element's text draws in, as an index. BEHIND THE
    /// SCENES: nothing in a `view` sets this.
    face: ?u16 = null,

    /// A fill is either a flat colour or a gradient, so one field covers both. Build one
    /// with `solid`, `hgrad` or `vgrad`. Point size, from a theme style.
    size: ?f32 = null,
    /// `wght` axis value, from a theme style. Null leaves the face at its default instance.
    weight: ?u16 = null,
    bg: ?Fill = null,
    color: ?Fill = null,
    border: ?Fill = null,
    /// Border width in logical pixels; absent means 1.
    border_width: ?f32 = null,
    /// `null` means the caller did not specify, which is what lets a widget merge a caller
    /// style over its own defaults and still let someone force a square.
    radius: ?f32 = null,
    pad: ?f32 = null,
    /// Appearance, not layout: an app can set a glow on any element, and a widget that
    /// wants a shadow by default can put one here.
    halo: ?Halo = null,
    /// Blur of what is behind this element. Nothing shows unless something is drawn under
    /// it, so it pairs with a translucent `bg`.
    frost: ?Frost = null,
    /// Outline width in pixels. Absent fills solid; a value leaves the interior
    /// hollow. `border` is a second pass, `stroke` replaces the fill.
    stroke: ?u8 = null,
    /// All four margins at once. A named side wins over this, and this wins over whatever
    /// the element already carried.
    margin: ?f32 = null,
    margin_left: ?f32 = null,
    margin_right: ?f32 = null,
    margin_top: ?f32 = null,
    margin_bottom: ?f32 = null,

    /// Size overrides. Same meaning as the bare fields on an Element, carried here so a
    /// named style can set them.
    width: ?f32 = null,
    height: ?f32 = null,
    /// Wrap text to the width layout gives the element.
    wrap: ?bool = null,
    /// Appearance while the pointer is over the element. Null means no hover feedback,
    /// which is the same rule the bare Element fields follow.
    hover: ?Fill = null,
    hover_halo: ?Halo = null,
    /// Appearance while the element owns the press.
    pressed: ?Fill = null,

    /// A NAMED theme style this tuple extends, e.g. `.style = .{ .name = "bold", .size = 12 }`.
    /// Resolved UNDER the other fields here, so anything written beside it still wins.
    /// A string, not a bare `.bold`: a bare identifier cannot carry a slice.
    name: ?[]const u8 = null,
    /// Alias of `name`. Both set is an error rather than one silently winning.
    class: ?[]const u8 = null,

    /// The theme style this tuple extends, requiring that `name` and `class` agree.
    /// Null when neither is set; never silent when both disagree.
    pub fn refName(self: Style) ?[]const u8 {
        const n = self.name;
        const c = self.class;
        if (n != null and c != null) {
            std.debug.assert(std.mem.eql(u8, n.?, c.?));
            return n;
        }
        return n orelse c;
    }

    /// Fold `s` over this style: every field `s` sets wins, everything else is
    /// kept. The same rule `Elem.mergeStyle` applies, but between two styles, so a
    /// builder can resolve a chain before the Element exists.
    pub fn merge(self: *Style, s: Style) void {
        inline for (@typeInfo(Style).@"struct".fields) |f| {
            // The reference keys are not values; they were followed already.
            if (comptime std.mem.eql(u8, f.name, "name")) continue;
            if (comptime std.mem.eql(u8, f.name, "class")) continue;
            const is_opt = @typeInfo(f.type) == .optional;
            if (!is_opt) @compileError("Style field '" ++ f.name ++ "' is not optional");
            if (@field(s, f.name)) |v| @field(self, f.name) = v;
        }
    }

    pub fn bgFill(self: Style, fallback: ?Fill) ?Fill {
        return self.bg orelse fallback;
    }
    pub fn colorFill(self: Style, fallback: ?Fill) ?Fill {
        return self.color orelse fallback;
    }
    pub fn borderFill(self: Style, fallback: ?Fill) ?Fill {
        return self.border orelse fallback;
    }
};

/// Merging two fills, one of which may have come from a flat `bg` and the other from a
/// gradient: a gradient wins over a flat colour.
fn mergeFill(old: ?Fill, new: ?Fill) ?Fill {
    const n = new orelse return old;
    if (n != .solid) return n;
    if (old) |o| {
        if (o != .solid) return o;
    }
    return n;
}

pub fn Element(comptime M: type) type {
    return struct {
        const Self = @This();

        geometry: Geometry,
        /// inner padding for containers
        pad: f32 = 0,
        /// gap between children, uniform by definition
        gap: f32 = 0,
        /// Space reserved AROUND this child inside the slot its container gives it.
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        /// overrides the measured width (useful inside rows)
        width: ?f32 = null,
        height: ?f32 = null,
        /// fills this element's rect before anything inside it is painted
        bg: ?Fill = null,
        /// what this element draws with on top of `bg`: text colour, control label, bar
        /// fill.
        color: ?Fill = null,
        /// Which registered typeface this element's text draws in. Set through
        /// `Style.face`, which is itself behind the scenes -- see `Style`.
        face: u16 = 0,
        /// `wght` axis for that face, or 0 for its default instance.
        weight: u16 = 0,
        /// A glow or shadow behind this element, following its corner radius. Appearance
        /// only: no layout cost, no hit region, no children moved.
        halo: ?Halo = null,
        /// Blur of what is already drawn behind this element, before the element's own
        /// fill.
        frost: ?Frost = null,
        /// Outline width in pixels. Absent fills solid; a value leaves the
        /// interior hollow. `border` is a second pass, `stroke` replaces the fill.
        stroke: ?u8 = null,
        /// A halo drawn only while the pointer is over this element, merged over `halo`.
        hover_halo: ?Halo = null,
        /// Inset outline, drawn inside the rect so it costs no layout.
        border: ?Fill = null,
        /// Border width in logical pixels; absent means 1.
        border_width: ?f32 = null,
        /// wrap text to the width layout gives this element
        wrap: bool = false,
        /// corner rounding; 0 = square. Clamped to half the shorter side.
        radius: f32 = 0,
        /// makes any element pressable, not just buttons
        on_press: ?M = null,
        /// What the runtime needs to ask this node after layout, if it is a Declares that
        /// this subtree is a FOCUS SCOPE keyed by this element.
        focus_scope: bool = false,
        /// Set by a builder on rows belonging to a roving control.
        roving: ?u64 = null,
        roving_index: u16 = 0,
        /// control.
        widget: ?*const Widget(M) = null,
        /// A short label shown once the pointer has rested here for a while.
        tooltip: ?[]const u8 = null,
        /// confine every descendant to this element's rect (rect clip only; rounded corners
        /// are not cut yet).
        clips: bool = false,
        /// Vertical scroll offset for a `scroll` geometry, in logical units.
        scroll_offset: f32 = 0,
        /// Runtime-written: this container's TREE PATH, hashed by the injection walk.
        scroll_key: ?u64 = null,
        /// Every node's position in the tree, stamped before paint.
        node_path: u64 = 0,
        /// The horizontal half of `scroll_offset`: both axes scroll on every container
        /// kind, so both offsets have to exist.
        scroll_offset_x: f32 = 0,
        /// background while the pointer is over this element. null = no hover feedback, so
        /// nothing that does not ask for it changes.
        hover: ?Fill = null,
        /// background while this element owns the press.
        pressed: ?Fill = null,
        /// refuses input: no hit region, no hover, no press visual.
        disabled: bool = false,
        /// Whether this element may hold focus.
        focusable: bool = false,
        /// In a ROW, take a share of the width left over after every non-grow child and the
        /// gaps have been paid for.
        grow: bool = false,
        /// Cross-axis placement of this row's children. See `RowAlign`.
        row_align: RowAlign = .stretch,
        /// identity for keyed children.
        key: ?u64 = null,
        /// Displacement from a stack's content origin, in logical units.
        offset: [2]f32 = .{ 0, 0 },

        /// What this element IS structurally: how it measures, how it paints, what it
        /// clips, and how a scroll offset descends through it.
        pub const Geometry = union(enum) {
            column: struct { children: []const *Self },
            row: struct { children: []const *Self },
            /// A viewport over ONE child: the child is laid out at its full height and
            /// painted shifted by `scroll_offset`, clipped to this element's box.
            scroll: struct { child: *Self },
            /// `face` is set through `Style.face`, never by a view: a style names a
            /// typeface, `Ui` resolves it against the registry and stores the INDEX here.
            text: struct { bytes: []const u8, size: f32, face: u16 = 0, weight: u16 = 0 },
            button: struct { label: []const u8, size: f32 },
            bar: struct { value: f32 },
            /// Children share ONE origin, each displaced by its own `offset`.
            stack: struct { children: []const *Self },
            /// a plain sized box; the only geometry with no intrinsic size
            rect: void,
            /// An SVG icon, drawn into whatever rect this element occupies.
            ///
            /// `path` is where the file LIVES, not its bytes: the renderer owns
            /// a cache keyed on the path, the size, the density and the tint,
            /// and reads the file once. Handing over bytes would put the
            /// lifetime of the source on the app.
            icon: struct { path: []const u8, col: [3]u8 },
            /// A raster image, drawn as decoded. No tint, so no colour here.
            ///
            /// `path` is where the file LIVES. `measure` reads its header for
            /// the aspect and paint blits the decoded pixels, so neither side
            /// has to know the file's contents at the other's expense.
            image: struct { path: []const u8, fit: ImageFit },
        };

        /// This element's appearance, read out as one value.
        pub fn style(self: *const Self) Style {
            return .{
                .bg = self.bg,
                .color = self.color,
                .border = self.border,
                // `border_width` belongs here for exactly the reason `face`
                // does below: anything that round-trips an element through
                // `style()` drops the field otherwise, and a border reverts to
                // the 1px default without any error.
                .border_width = self.border_width,
                // `face` belongs here or the round trip drops it: `finish` reads
                // the face back off `style()` to copy it into the text geometry,
                // so a `style()` that omits the field makes that copy a no-op.
                // The element carried the right face; this projection dropped it,
                // and every styled label painted in the primary face -- tofu for
                // any script the primary does not cover.
                .face = self.face,
                .weight = self.weight,
                .radius = self.radius,
                .pad = self.pad,
                .halo = self.halo,
                .frost = self.frost,
                .stroke = self.stroke,
                // The six added with the `.style` overhaul. Omitting any of them is
                // the same silent round-trip loss that dropped `border_width` and
                // `face`: the element carries the value, this projection returns
                // null, and whoever reads `style()` sees a default.
                .width = self.width,
                .height = self.height,
                .wrap = self.wrap,
                .hover = self.hover,
                .hover_halo = self.hover_halo,
                .pressed = self.pressed,
            };
        }

        /// The ONLY intended writer of the appearance fields, and the reason they are
        /// grouped: one call replaces eight assignments.
        pub fn applyStyle(self: *Self, s: Style) void {
            self.bg = mergeFill(self.bg, s.bg);
            self.color = mergeFill(self.color, s.color);
            self.border = mergeFill(self.border, s.border);
            if (s.border_width) |v| self.border_width = v;
            if (s.face) |v| self.face = v;
            if (s.weight) |v| self.weight = v;
            self.radius = s.radius orelse 0;
            self.pad = s.pad orelse 0;
            self.halo = s.halo;
            self.frost = s.frost;
            self.stroke = s.stroke;
            if (s.hover) |v| self.hover = v;
            if (s.hover_halo) |v| self.hover_halo = v;
            if (s.pressed) |v| self.pressed = v;
            if (s.width) |v| self.width = v;
            if (s.height) |v| self.height = v;
            if (s.wrap) |v| self.wrap = v;
            if (s.margin) |m| {
                self.margin_left = m;
                self.margin_right = m;
                self.margin_top = m;
                self.margin_bottom = m;
            }
            if (s.margin_left) |v| self.margin_left = v;
            if (s.margin_right) |v| self.margin_right = v;
            if (s.margin_top) |v| self.margin_top = v;
            if (s.margin_bottom) |v| self.margin_bottom = v;
        }

        /// Overlay `s` on what this element already has: only the fields the caller
        /// actually set are written. This is the one widgets need.
        pub fn mergeStyle(self: *Self, s: Style) void {
            if (s.bg) |v| self.bg = v;
            if (s.color) |v| self.color = v;
            if (s.border) |v| self.border = v;
            if (s.border_width) |v| self.border_width = v;
            if (s.face) |v| self.face = v;
            if (s.weight) |v| self.weight = v;
            if (s.radius) |v| self.radius = v;
            if (s.pad) |v| self.pad = v;
            if (s.halo) |v| self.halo = v;
            if (s.frost) |v| self.frost = v;
            if (s.stroke) |v| self.stroke = v;
            if (s.hover) |v| self.hover = v;
            if (s.hover_halo) |v| self.hover_halo = v;
            if (s.pressed) |v| self.pressed = v;
            if (s.width) |v| self.width = v;
            if (s.height) |v| self.height = v;
            if (s.wrap) |v| self.wrap = v;
            if (s.margin) |v| {
                self.margin_left = v;
                self.margin_right = v;
                self.margin_top = v;
                self.margin_bottom = v;
            }
            if (s.margin_left) |v| self.margin_left = v;
            if (s.margin_right) |v| self.margin_right = v;
            if (s.margin_top) |v| self.margin_top = v;
            if (s.margin_bottom) |v| self.margin_bottom = v;
        }

        /// Totals a row shares out.
        const RowFit = struct {
            total_w: f32 = 0,
            total_min: f32 = 0,
            /// Everything the grow shares cannot eat: the non-grow children with their
            /// spacing, plus the gaps between everyone.
            fixed_w: f32 = 0,
            n_grow: usize = 0,
            inner: f32 = 0,
        };

        fn rowFit(r: Renderer, children: []const *Self, gap: f32, inner: f32) RowFit {
            var fit: RowFit = .{ .inner = inner };
            for (children, 0..) |ch, i| {
                const cs = ch.measure(r, inner);
                if (i > 0) {
                    fit.total_w += gap;
                    fit.total_min += gap;
                    fit.fixed_w += gap;
                }
                fit.total_w += ch.margin_left + cs.w + ch.margin_right;
                fit.total_min += ch.margin_left + cs.min_w + ch.margin_right;
                if (ch.grow) {
                    fit.n_grow += 1;
                } else {
                    fit.fixed_w += ch.margin_left + cs.w + ch.margin_right;
                }
            }
            return fit;
        }

        /// Final width for one row child.
        fn rowWidth(cs: Extent, ch: *const Self, fit: RowFit) f32 {
            if (ch.grow and fit.n_grow > 0 and fit.total_w <= fit.inner) {
                const n: f32 = @floatFromInt(fit.n_grow);
                return @max((fit.inner - fit.fixed_w) / n, cs.min_w);
            }
            return rowChildWidth(cs, fit.total_w, fit.total_min, fit.inner);
        }

        /// Distance from this element's TOP edge down to the baseline of the first line of
        /// text it will draw, or null when it draws none.
        fn textBaseline(self: *const Self, r: Renderer, w: f32, h: f32) ?f32 {
            switch (self.geometry) {
                .text => |t| return self.pad + r.measureTextFace(t.bytes, t.size, t.face).ascent,
                // An image has no text, so no baseline.
                .image => return null,
                .button => |b| {
                    const ts = r.measureText(b.label, b.size);
                    return (h - ts.height) * 0.5 + ts.ascent;
                },
                .column => |c| {
                    const inner_w = w - 2 * self.pad;
                    var y = self.pad;
                    for (c.children, 0..) |ch, i| {
                        if (i > 0) y += self.gap;
                        y += ch.margin_top;
                        const cs = ch.measure(r, inner_w);
                        if (ch.textBaseline(r, ch.width orelse inner_w, cs.h)) |b| return y + b;
                        y += cs.h;
                        y += ch.margin_bottom;
                    }
                    return null;
                },
                .row => |c| {
                    const inner_w = w - 2 * self.pad;
                    for (c.children) |ch| {
                        const cs = ch.measure(r, inner_w);
                        if (ch.textBaseline(r, ch.width orelse inner_w, cs.h)) |b| return self.pad + ch.margin_top + b;
                    }
                    return null;
                },
                .bar, .rect, .stack, .scroll, .icon => return null,
            }
        }

        /// Height (and resolved width) at `avail_w` — the width the parent is about to give
        /// this element.
        pub fn measure(self: *const Self, r: Renderer, avail_w: f32) Extent {
            var s: Extent = switch (self.geometry) {
                .text => |t| blk: {
                    // Measured on the face it will be PAINTED with, not the
                    // primary. See `measure_text_face`.
                    const ts = r.measureTextFace(t.bytes, t.size, t.face);
                    // An explicit width still wins; otherwise wrapping text
                    // takes what it is given, since it has no natural width.
                    const max_w = self.width orelse avail_w;
                    if (self.wrap and std.math.isFinite(max_w) and max_w > 0) {
                        var buf: [max_lines][]const u8 = undefined;
                        const inner = max_w - 2 * self.pad;
                        const n = r.wrapText(t.bytes, t.size, inner, &buf);
                        break :blk .{
                            .w = max_w,
                            .h = ts.height + @as(f32, @floatFromInt(n - 1)) * ts.line_height + 2 * self.pad,
                            .min_w = longestWord(r, t.bytes, t.size) + 2 * self.pad,
                        };
                    }
                    // `pad` grows the box on every geometry, so a filled text
                    // element is a chip and not a label with its edges shaved.
                    const tw = ts.width + 2 * self.pad;
                    break :blk .{ .w = tw, .h = ts.height + 2 * self.pad, .min_w = tw };
                },
                .button => |b| blk: {
                    const ts = r.measureText(b.label, b.size);
                    // A label does not break, so a button's floor is its width.
                    const bw = ts.width + 24;
                    break :blk .{ .w = bw, .h = ts.height + 16, .min_w = bw };
                },
                .bar => .{ .w = 0, .h = 10, .min_w = 0 },
                // Square by default: an icon has no intrinsic text to measure,
                // and a viewBox-derived aspect would be a lie for an SVG that
                // has none. A caller wanting another shape sets width/height.
                .icon => .{ .w = 24, .h = 24, .min_w = 0 },
                // Shrink to the image's aspect, like text shrinks to its
                // intrinsic width. The aspect comes from a HEADER read, not a
                // decode, so this is stable whether or not the raster is
                // resident -- which is the whole reason a miss cannot change
                // layout.
                //
                // An unreadable image falls back to square rather than failing:
                // one broken file should not take out a layout pass, and a
                // square is the honest default for "we do not know".
                .image => |im| blk: {
                    const natural = r.imageSize(im.path) orelse
                        break :blk .{ .w = 24, .h = 24, .min_w = 0 };
                    const asp: f32 = @as(f32, @floatFromInt(natural[0])) / @as(f32, @floatFromInt(natural[1]));
                    // Width is whatever the parent offers (or an explicit
                    // width); height follows the aspect. `.stretch` has no
                    // opinion, so it takes the same box and lets paint fill it.
                    const w = self.width orelse avail_w;
                    if (!std.math.isFinite(w) or w <= 0) {
                        break :blk .{ .w = 24, .h = 24 / asp, .min_w = 0 };
                    }
                    break :blk .{ .w = w, .h = (w - 2 * self.pad) / asp + 2 * self.pad, .min_w = 0 };
                },
                .rect => .{ .w = 0, .h = 0, .min_w = 0 },
                .column => |c| blk: {
                    const inner_avail = (self.width orelse avail_w) - 2 * self.pad;
                    var w: f32 = 0;
                    var min_w: f32 = 0;
                    var h: f32 = 0;
                    for (c.children, 0..) |ch, i| {
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, inner_avail);
                        // Cross-axis margins: a column never competes over width,
                        // so they simply make this child's slot wider and the
                        // child narrower inside it.
                        w = @max(w, ch.margin_left + cs.w + ch.margin_right);
                        // A column stacks, so it is only as squeezable as its
                        // widest floor. Children do not compete for width.
                        min_w = @max(min_w, ch.margin_left + cs.min_w + ch.margin_right);
                        if (i > 0) h += self.gap;
                        h += ch.margin_top;
                        h += cs.h;
                        h += ch.margin_bottom;
                    }
                    break :blk .{ .w = w + 2 * self.pad, .h = h + 2 * self.pad, .min_w = min_w + 2 * self.pad };
                },
                .row => |c| blk: {
                    // A row is the one container where children COMPETE: they
                    // are laid side by side, so the widths have to be shared
                    // out rather than summed. `rowFit` collects the totals once
                    // and paint calls the same pair, because measure and paint
                    // disagreeing about a width is how a child ends up painted
                    // somewhere it was never measured.
                    const inner = (self.width orelse avail_w) - 2 * self.pad;
                    for (c.children) |ch| {
                        if (self.disabled) ch.disabled = true;
                    }
                    const fit = rowFit(r, c.children, self.gap, inner);
                    // A baseline row cannot be measured one child at a time:
                    // the common baseline is the DEEPEST one, so every height
                    // has to be known before any of them is placed. That is one
                    // extra pass over the children, paid only by rows that ask
                    // for it -- which is why this is not folded into the loop
                    // below.
                    var max_base: f32 = 0;
                    if (self.row_align == .baseline) {
                        for (c.children) |ch| {
                            const cs = ch.measure(r, inner);
                            const cw = rowWidth(cs, ch, fit);
                            const at = if (cw < cs.w) ch.measure(r, cw) else cs;
                            // An element with no text aligns its BOTTOM edge.
                            // That is what a baseline-less box does in CSS, and
                            // it is the answer that keeps a colour swatch or a
                            // divider level with the label beside it instead of
                            // floating at the top.
                            // The margin is part of the slot, so the baseline to
                            // line up against sits `margin_top` below the slot's
                            // top edge.
                            const b = ch.textBaseline(r, cw, at.h) orelse at.h;
                            max_base = @max(max_base, ch.margin_top + b);
                        }
                    }
                    var h: f32 = 0;
                    for (c.children) |ch| {
                        const cs = ch.measure(r, inner);
                        const cw = rowWidth(cs, ch, fit);
                        // A child given less than it asked for has to be
                        // re-measured at the width it actually got, or the row
                        // reserves a height no child ever paints at.
                        const at = if (cw < cs.w) ch.measure(r, cw) else cs;
                        if (self.row_align == .baseline) {
                            // The row is as tall as the deepest baseline plus
                            // the tallest descent below it, NOT the tallest
                            // child: dropping a short child moves it down, and
                            // its bottom edge can end up below its neighbour's.
                            const b = ch.textBaseline(r, cw, at.h) orelse at.h;
                            h = @max(h, (max_base - ch.margin_top - b) + ch.margin_top + at.h + ch.margin_bottom);
                        } else {
                            // Cross-axis margins are height the row must find,
                            // exactly as if the child were that much taller.
                            h = @max(h, at.h + ch.margin_top + ch.margin_bottom);
                        }
                    }
                    // A grow child eats the leftover, so the row claims the
                    // width it was offered rather than the sum of the parts.
                    const w = if (fit.n_grow > 0) inner else @min(fit.total_w, inner);
                    break :blk .{
                        .w = w + 2 * self.pad,
                        .h = h + 2 * self.pad,
                        .min_w = fit.total_min + 2 * self.pad,
                    };
                },
                .stack => |c| blk: {
                    const inner_avail = (self.width orelse avail_w) - 2 * self.pad;
                    var w: f32 = 0;
                    var min_w: f32 = 0;
                    var h: f32 = 0;
                    for (c.children) |ch| {
                        if (self.disabled) ch.disabled = true;
                        // Every child is measured at the FULL inner width: they
                        // are not side by side, so nothing is being shared out
                        // and there is no reason to squeeze anyone.
                        const cs = ch.measure(r, inner_avail);
                        w = @max(w, ch.offset[0] + cs.w);
                        min_w = @max(min_w, ch.offset[0] + cs.min_w);
                        h = @max(h, ch.offset[1] + cs.h);
                    }
                    // A child hanging off the top or left does not make the box
                    // smaller: the content box starts at zero whatever is
                    // outside it, and a negative extent is not a size.
                    break :blk .{
                        .w = @max(0, w) + 2 * self.pad,
                        .h = @max(0, h) + 2 * self.pad,
                        .min_w = @max(0, min_w) + 2 * self.pad,
                    };
                },
                .scroll => |c| blk: {
                    // A viewport takes its child's width and its own height.
                    // The child is measured at full height and clipped, which
                    // is the whole difference from an ordinary column.
                    const inner_w = (self.width orelse avail_w) - 2 * self.pad;
                    if (self.disabled) c.child.disabled = true;
                    const cs = c.child.measure(r, inner_w);
                    break :blk .{
                        .w = cs.w + 2 * self.pad,
                        .h = self.height orelse (cs.h + 2 * self.pad),
                        .min_w = cs.min_w + 2 * self.pad,
                    };
                },
            };
            // An explicit width is both what the element takes and its floor:
            // a parent may not squeeze past a number the app wrote down.
            if (self.width) |w| {
                s.w = w;
                s.min_w = w;
            }
            if (self.height) |h| s.h = h;
            return s;
        }

        /// A column's content extent: the sum down its main axis, and the widest child
        /// across it. Both are needed now that either axis can overflow.
        fn columnContent(r: Renderer, kids: []const *Self, gap: f32, inner_w: f32) struct { w: f32, h: f32 } {
            var h: f32 = 0;
            var w: f32 = 0;
            for (kids, 0..) |ch, i| {
                if (i > 0) h += gap;
                const cs = ch.measure(r, inner_w);
                h += ch.margin_top + cs.h + ch.margin_bottom;
                w = @max(w, ch.margin_left + (ch.width orelse cs.w) + ch.margin_right);
            }
            return .{ .w = w, .h = h };
        }

        /// A row's cross-axis extent: the tallest child, floored at the box so a row that
        /// fits reports nothing to scroll.
        fn rowContentHeight(r: Renderer, kids: []const *Self, avail_w: f32, inner_h: f32) f32 {
            var h: f32 = inner_h;
            for (kids) |ch| {
                const cs = ch.measure(r, avail_w);
                h = @max(h, ch.margin_top + cs.h + ch.margin_bottom);
            }
            return h;
        }

        const ScrollFit = struct {
            max_x: f32 = 0,
            max_y: f32 = 0,
            off_x: f32 = 0,
            off_y: f32 = 0,
            vp: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            fn active(f: ScrollFit) bool {
                return f.max_x > 0 or f.max_y > 0;
            }
        };

        /// THE RULE, in one place: compare content extent against the box the parent
        /// painted, per axis. No declaration, no height, no key.
        fn scrollFit(self: *const Self, inner: Rect, clip: Rect, cw: f32, ch: f32) ScrollFit {
            if (inner.w <= 0 or inner.h <= 0) return .{ .vp = clip };
            const max_x = @max(0, cw - inner.w);
            const max_y = @max(0, ch - inner.h);
            if (max_x <= 0 and max_y <= 0) return .{ .vp = clip };
            return .{
                .max_x = max_x,
                .max_y = max_y,
                // Clamped on READ: the store is written by a frame that may have
                // had different content, so clamping here is what stops it
                // painting blank space past the end.
                .off_x = if (max_x > 0) std.math.clamp(self.scroll_offset_x, 0, max_x) else 0,
                .off_y = if (max_y > 0) std.math.clamp(self.scroll_offset, 0, max_y) else 0,
                .vp = inner.intersect(clip),
            };
        }

        /// Everything a scrolling container owes the runtime: the region the wheel targets,
        /// and whichever thumbs apply.
        fn scrollChrome(
            self: *const Self,
            r: Renderer,
            th: Theme,
            inner: Rect,
            f: ScrollFit,
            cw: f32,
            ch: f32,
            hits: *std.ArrayList(Hit(M)),
            gpa: Allocator,
            generic_at: usize,
        ) Allocator.Error!void {
            if (!f.active() or f.vp.isEmpty()) return;
            const info: ScrollView = .{ .content_h = ch, .view_h = inner.h, .content_w = cw, .view_w = inner.w };
            if (hits.items.len > generic_at) {
                // Upgrade the region the generic pass already recorded: it is
                // this element's identity, and a second hit under the same key
                // would trip the frame-global duplicate-key guard.
                const hit = &hits.items[generic_at];
                hit.scroll = info;
                hit.scroll_id = self.scroll_key;
            } else if (self.scroll_key) |sid| try hitAppend(M, hits, gpa, .{
                .rect = inner,
                .clip = f.vp,
                .msg = self.on_press,
                .key = self.key orelse self.scroll_key,
                .active = !self.disabled,
                .focusable = self.focusable,
                .scroll = info,
                .scroll_id = sid,
            });
            if (self.scroll_key) |k| {
                if (thumbHit(inner, f.vp, ch, f.off_y, f.max_y, k, !self.disabled)) |h| try hits.append(gpa, h);
                if (thumbHitH(inner, f.vp, cw, f.off_x, f.max_x, k, !self.disabled)) |h| try hits.append(gpa, h);
            }
            paintScrollbar(r, th, inner, f.vp, ch, f.off_y, f.max_y);
            paintScrollbarH(r, th, inner, f.vp, cw, f.off_x, f.max_x);
        }

        /// The vertical scrollbar, painted last so content cannot cover it, and only when
        /// there is something to scroll.
        fn paintScrollbar(r: Renderer, th: Theme, inner: Rect, vp: Rect, content_h: f32, off: f32, max_off: f32) void {
            if (max_off <= 0 or inner.w <= 2 * scrollbar_w or content_h <= 0) return;
            const track = inner.h;
            const thumb_h = @min(track, @max(scrollbar_min_thumb, track * (track / content_h)));
            const ty = inner.y + (track - thumb_h) * (off / max_off);
            r.quad(
                .{ .x = inner.x + inner.w - scrollbar_w, .y = ty, .w = scrollbar_w, .h = thumb_h },
                .{ .solid = th.border },
                vp,
            );
        }

        /// The thumb's grab region: wider than the 6px it draws, because a strip that can
        /// only be hit on the pixel it paints is not draggable in practice.
        fn thumbHit(inner: Rect, vp: Rect, content_h: f32, off: f32, max_off: f32, key: u64, active: bool) ?Hit(M) {
            if (max_off <= 0 or inner.w <= 2 * scrollbar_w or content_h <= 0) return null;
            const track = inner.h;
            const thumb_h = @min(track, @max(scrollbar_min_thumb, track * (track / content_h)));
            const ty = inner.y + (track - thumb_h) * (off / max_off);
            const grab_w = @min(inner.w, scrollbar_grab);
            return .{
                .rect = .{ .x = inner.x + inner.w - grab_w, .y = ty, .w = grab_w, .h = thumb_h },
                .clip = vp,
                .active = active,
                .drag = .{ .thumb = .{ .key = key, .horizontal = false, .view = .{ .content_h = content_h, .view_h = inner.h } } },
            };
        }

        /// The horizontal twin of `paintScrollbar`: a bar along the bottom edge.
        fn paintScrollbarH(r: Renderer, th: Theme, inner: Rect, vp: Rect, content_w: f32, off: f32, max_off: f32) void {
            if (max_off <= 0 or inner.h <= 2 * scrollbar_w or content_w <= 0) return;
            const track = inner.w;
            const thumb_w = @min(track, @max(scrollbar_min_thumb, track * (track / content_w)));
            const tx = inner.x + (track - thumb_w) * (off / max_off);
            r.quad(
                .{ .x = tx, .y = inner.y + inner.h - scrollbar_w, .w = thumb_w, .h = scrollbar_w },
                .{ .solid = th.border },
                vp,
            );
        }

        fn thumbHitH(inner: Rect, vp: Rect, content_w: f32, off: f32, max_off: f32, key: u64, active: bool) ?Hit(M) {
            if (max_off <= 0 or inner.h <= 2 * scrollbar_w or content_w <= 0) return null;
            const track = inner.w;
            const thumb_w = @min(track, @max(scrollbar_min_thumb, track * (track / content_w)));
            const tx = inner.x + (track - thumb_w) * (off / max_off);
            const grab_h = @min(inner.h, scrollbar_grab);
            return .{
                .rect = .{ .x = tx, .y = inner.y + inner.h - grab_h, .w = thumb_w, .h = grab_h },
                .clip = vp,
                .active = active,
                .drag = .{ .thumb = .{ .key = key, .horizontal = true, .view = .{ .content_h = content_w, .view_h = inner.w, .content_w = content_w, .view_w = inner.w } } },
            };
        }

        pub fn paint(
            self: *const Self,
            r: Renderer,
            rect: Rect,
            clip: Rect,
            ptr: PointerView,
            hits: *std.ArrayList(Hit(M)),
            gpa: Allocator,
            hov: Hover,
            th: Theme,
        ) Allocator.Error!void {
            // Every element starts on the primary face. `setFace` is sticky
            // until told otherwise, and only TEXT elements call it, so without
            // this a label styled in a second typeface would leak that font into
            // the button and tooltip drawn after it. Resetting here makes the
            // leak structurally impossible instead of fixing it per call site.
            r.setFace(0);

            // What this element's own drawing is confined to: the clip it
            // inherited. Its children get one more intersection if it clips.
            const child_clip = if (self.clips) rect.intersect(clip) else clip;

            // Everything recorded from here down belongs to this scope, and it
            // is stamped on the way OUT: the subtree is measured as it paints,
            // so the region list is only complete once the children are done.
            // Doing it here rather than threading a parameter through `paint`
            // keeps one source of truth -- the element that declared the scope.
            const scope_start = hits.items.len;
            defer if (self.focus_scope) {
                if (self.key) |k| {
                    // Only claim hits nothing closer has claimed. A nested
                    // scope stamps its own range first (its defer runs at the
                    // inner return), and an unconditional write here would
                    // flatten every scope in the subtree onto the outermost
                    // one -- so a panel inside a dialog would trap focus for
                    // the dialog instead of for itself.
                    for (hits.items[scope_start..]) |*h| {
                        if (h.scope == null) h.scope = k;
                    }
                }
            };

            // Derived appearance. A press in flight beats hover, and it beats
            // it everywhere: while one element owns the press, nothing else
            // lights up. That is capture made visible.
            //
            // Both tests are identity, not overlap. An ancestor overlaps the
            // child it contains, so an overlap test would light up every
            // container with a pressable child in it.
            // Every element has an identity. An explicit `key` wins; otherwise
            // the tree path stands in, so `key` is optional everywhere it is
            // merely needed to BE somebody -- focus, a press that outlives a
            // reorder, tooltip plumbing. The path is unique per node by
            // construction, so a synthesized key cannot collide in the
            // frame-global duplicate-key guard the way an author one can.
            const kid: u64 = self.key orelse self.node_path;
            var bg_now: ?Fill = self.style().bgFill(null);
            if (!self.disabled) {
                if (ptr.held) |held| {
                    if (self.pressed) |pc| {
                        // Rect identity keeps a press through a reflow; key
                        // identity keeps it through a reorder, where the rect
                        // is no longer the one that was pressed.
                        if (held.eql(rect, clip) or (held.key == kid)) bg_now = pc;
                    }
                } else if (self.hover) |hc| {
                    if (hov.target) |target| {
                        if (target.eql(rect, clip)) bg_now = hc;
                    } else if (ptr.pos) |p| {
                        // No resolution pass ran (single-pass call): fall back to
                        // containment, which is what a caller painting in isolation
                        // can honour.
                        if (rect.contains(p) and clip.contains(p)) bg_now = hc;
                    }
                }
            }
            // A tooltip rides the same scan as hover and for the same reason:
            // both answer "what is under the pointer", and a second traversal
            // would be a second place for that answer to disagree. Recorded even
            // for a DISABLED element -- "why is this greyed out" is the main
            // reason to have a tooltip at all.
            if (self.hover != null or self.tooltip != null) {
                if (hov.out) |out| try out.append(gpa, .{ .rect = rect, .clip = clip, .key = kid, .active = !self.disabled, .radius = self.radius, .tooltip = self.tooltip });
            }
            // A button or bar always fills, even with no `bg` set, so the
            // geometry default belongs here rather than in the geometry's paint arm.
            // It has to be resolved in exactly one place: when the geometry arm
            // drew its own fill as well, a button with `bg` set emitted two
            // quads over the same rect (invisible, but wrong -- and it made
            // prim counts a lie).
            // One foreground decision for every geometry: a disabled control keeps
            // its geometry and drops to the muted role, which is the only
            // signal it gets, since the theme has no disabled colour and
            // cannot get one without duplicating a Mocha step.
            const fg_now: Fill = if (self.disabled) .{ .solid = th.text_muted } else self.style().colorFill(.{ .solid = th.text }).?;
            // Focus is the third derived appearance, after press and hover: the
            // runtime names a key, the element asks whether it is that key. A
            // focused control shows the accent as its border, so apps never
            // paint a ring themselves and the theme still owns the colour.
            // Focus names an IDENTITY, not a rectangle: the runtime says which
            // key holds it, and each element asks whether that key is its own.
            // An unkeyed element can never match, so `focusable` alone draws
            // nothing -- which is the intended contract, not a special case.
            const focused = self.focusable and !self.disabled and
                hov.focus != null and hov.focus.? == kid;
            const border_now: ?Fill = if (focused and !self.disabled) .{ .solid = th.accent } else self.style().borderFill(null);
            const fill_now: ?Fill = bg_now orelse switch (self.geometry) {
                .button, .bar => .{ .solid = th.control },
                else => null,
            };
            // Halos composite BEHIND the element: a shadow is the silhouette
            // of the thing, a glow is light around it, and either one drawn on
            // top would cover the element it belongs to. Clipped to the
            // INHERITED clip, never to the element's own rect -- a halo that
            // could not leave the box would be a border.
            const hovered = blk: {
                if (self.disabled) break :blk false;
                if (ptr.held) |held| break :blk held.eql(rect, clip) or held.key == kid;
                if (hov.target) |target| break :blk target.eql(rect, clip);
                if (ptr.pos) |p| break :blk rect.containsRounded(self.radius, p) and clip.contains(p);
                break :blk false;
            };
            const halo_now: ?Halo = if (hovered) self.hover_halo orelse self.halo else self.halo;
            // Backdrop first: a frost reads what is behind it, so it has to run
            // while the destination is still the backdrop and not the element.
            if (self.frost) |fr| r.frost(rect, self.radius, fr.blur, clip);
            // A themed `stroke` draws the fill as an outline rather than a solid,
            // which is the one thing a theme could not ask for before: `border`
            // is a second pass, `stroke` replaces the fill.
            //
            // EXCEPT on an element that draws TEXT. There the stroke belongs on
            // the GLYPHS -- the whole point of the distance field -- so filling
            // the box with it would draw a rim round the label as well. `bg`
            // still fills the box: that is the element's backdrop, and it is
            // what a stroked label sits on.
            const strokes_text = self.geometry == .text;
            // A text element's `stroke` belongs to its GLYPHS, so the box must
            // not take it -- and it must not fall back to a solid quad either.
            // `stroke` used to double as "outline instead of fill", so clearing
            // it here turned the fill back ON and painted the label's box solid
            // over the text. That is the two-solid-rects bug.
            const stroke_now: ?u8 = if (strokes_text) null else self.stroke;
            const box_fill: ?Fill = if (strokes_text) null else fill_now;
            // Themed border width, in LOGICAL pixels like `radius` -- the
            // renderer scales it. Absent means 1, which is what every theme
            // written before the field draws.
            const bw_f: f32 = @max(self.border_width orelse 1, 0);
            const bw_i: u8 = @intFromFloat(@max(@min(bw_f, 255.0), 1.0));
            // On an element that draws TEXT, `.border` belongs to the GLYPHS,
            // for the same reason `.stroke` and `.halo` do: a rim round the
            // label's box is not what "outline this text" means. The box path
            // below therefore skips it entirely, exactly as it skips `stroke`.
            const border_now_box: ?Fill = if (strokes_text) null else border_now;
            if (self.radius > 0) {
                if (box_fill) |c| r.roundedRect(rect, self.radius, c, stroke_now, clip);
                if (border_now_box) |c| r.roundedRect(rect, self.radius, c, bw_i, clip);
            } else {
                if (box_fill) |c| {
                    if (stroke_now != null) r.roundedRect(rect, 0, c, stroke_now, clip) else r.quad(rect, c, clip);
                }
                if (border_now_box) |b| {
                    // Four quads only serve a 1px solid border: their boxes are
                    // one pixel on the short axis, so a gradient's ramp would
                    // restart per edge and collapse to one stop, and a thicker
                    // border drawn as four full-length rects would overlap its
                    // own corners. Everything else goes through the SDF stroke,
                    // which evaluates a true inset ring against the element rect.
                    if (b.isSolid() and bw_i == 1) {
                        r.quad(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, b, clip);
                        r.quad(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, b, clip);
                        r.quad(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, b, clip);
                        r.quad(.{ .x = rect.x + rect.w - 1, .y = rect.y, .w = 1, .h = rect.h }, b, clip);
                    } else {
                        r.roundedRect(rect, 0, b, bw_i, clip);
                    }
                }
            }
            // One emission point, one order, for every mode. `.glow` keeps BOTH
            // halves of the ramp, so the inner one has to land on the face -- under
            // the fill it would simply be covered. `.outer_glow` cuts the inner
            // half and `.inner_glow` cuts the outer one, so the same order is
            // correct for all three and no mode needs a rule of its own.
            //
            // EXCEPT on an element that draws TEXT. There the halo belongs on
            // the GLYPHS -- the same reason `stroke` moves to the glyphs rather
            // than outlining the label's box. Drawing the box halo too would put
            // a rounded rectangle behind a word, which is what a text element
            // used to get: `.halo` read as a rect because nothing told it the
            // element was text.
            const is_text = self.geometry == .text;
            const text_halo_now: ?Halo = if (is_text) halo_now else null;
            if (!is_text) {
                if (halo_now) |h| r.halo(rect, self.radius, h, clip);
            }
            // A region exists for anything the runtime must be able to FIND,
            // not only for things that produce a message: a focusable control
            // with no message is exactly the case where Tab had nothing to
            // land on, because the only region recorded was a press.
            // A keyed scroll viewport records its OWN region further down: that
            // region has to carry the scroll extent, and it has to be laid down
            // before the content so a control inside still wins the pointer.
            // Emitting the generic region as well would put two hits under one
            // key, and the frame-global duplicate-key guard would then report
            // an app for using the feature as documented.
            const viewport_claims_this = std.meta.activeTag(self.geometry) == .scroll;
            // Where the generic region lands. A container that turns out to
            // overflow UPGRADES that region with its scroll extent instead of
            // appending a second one under the same key: two hits per key trips
            // the frame-global duplicate-key guard, which would report an app
            // for using the feature as documented.
            const generic_at = hits.items.len;
            // A widget-bearing element records a region even with no message
            // and no focus: the runtime has to FIND it to open a popup, move a
            // highlight or start a drag, and a slider produces no message of
            // its own until one of those happens.
            if (!viewport_claims_this and (self.on_press != null or self.focusable or self.widget != null)) {
                try hitAppend(M, hits, gpa, .{
                    .rect = rect,
                    .clip = clip,
                    .msg = self.on_press,
                    .key = kid,
                    .active = !self.disabled,
                    .radius = self.radius,
                    .focusable = self.focusable,
                    .widget = self.widget,
                    .roving = self.roving,
                    .roving_index = self.roving_index,
                    // Only a slider takes the pointer as a drag. Everything else
                    // with a widget is a press or a popup anchor, and a region
                    // that claimed a drag without a mapping would swallow motion
                    // it has no way to use.
                    .drag = if (self.widget) |w| switch (w.*) {
                        .slider => |sl| Drag{ .slider = .{
                            .key = self.key orelse 0,
                            .rect = rect,
                            .value = sl.value,
                            .min = sl.min,
                            .max = sl.max,
                            .step = sl.step,
                            .orientation = sl.orientation,
                        } },
                        else => null,
                    } else null,
                });
            }

            switch (self.geometry) {
                .text => |t| {
                    // The typeface this label was styled in. Set once here and
                    // sticky for the runs below, so a wrapped paragraph does not
                    // repeat the index on every line. Unconditional, not
                    // `!= 0`-guarded: an element with no face must CLEAR one the
                    // previous element set, or a single styled label would leak
                    // its font into everything drawn after it this frame.
                    r.setFace(t.face);
                    // After the face, never before: `setFace` resets the weight
                    // to the face's default instance, so setting it first would
                    // be discarded.
                    r.setWeight(t.weight);
                    // Glyphs start inside the padding, matching `measure`.
                    const ix = rect.x + self.pad;
                    const iy = rect.y + self.pad;
                    const iw = rect.w - 2 * self.pad;
                    const ih = rect.h - 2 * self.pad;
                    // Text is contained by its OWN box, not merely by the clip
                    // it inherited. A label wider than its element used to paint
                    // straight over its own background and its neighbour, which
                    // was tolerable while every label was placed by hand and is
                    // not tolerable once a widget can be given a width.
                    // A hair of slack. A glyph's ink can overhang its advance
                    // width by a fraction of a pixel, so a box exact to the
                    // measurement shaves the last column of coverage off a label
                    // that does fit -- and at a fractional density the boundary
                    // lands mid-pixel and takes whole columns with it. The box is
                    // for containment, not for enforcing the advance sum.
                    // Scaled with the type, because ink overhang does: a
                    // 34px heading can hang two or three pixels outside its
                    // advance box, and a fixed pixel of slack would shave it.
                    const slack = @max(1.0, t.size * 0.1);
                    const tclip = clip.intersect(.{
                        .x = ix - slack,
                        .y = iy - slack,
                        .w = iw + 2 * slack,
                        .h = ih + 2 * slack,
                    });
                    if (tclip.isEmpty()) return;
                    if (!self.wrap or iw <= 0) {
                        // Elided rather than left to spill: a glyph cut in half
                        // by a clip reads as a rendering fault, and the width a
                        // widget hands its label is not the app's to predict.
                        // Elide against the same box the clip uses, not the raw
                        // width: a row that squeezes a label by a pixel must not
                        // lose two characters and gain an ellipsis for it.
                        const fit = fitText(r, t.bytes, t.size, iw + 2 * slack);
                        // A stroked label outlines its GLYPHS. `bg` above still
                        // fills the box -- that is the element's backdrop, not
                        // the stroke, which is why `.stroke` alone leaves the
                        // interior empty and `.bg` + `.stroke` reads as a
                        // labelled panel with outlined letters.
                        // Glow rides the text prim, so it lands BEHIND the
                        // glyphs without needing its own z slot.
                        if (text_halo_now) |hs| r.textHalo(ix, iy, t.size, hs, fit.bytes, tclip);
                        // A GLYPH BORDER, outlined before the letters so they
                        // sit inside their own rim. The box border was cleared
                        // for a text element above; this is the same field
                        // painted round the glyphs instead of the rect.
                        if (border_now) |bf| r.borderedText(ix, iy, t.size, bf, fit.bytes, bw_i, tclip);
                        // A GLYPH BORDER was already queued as its own prim by
                        // `vtBorderedText`, which paints before this fill. All
                        // that is left here is the letters themselves, in the
                        // style's text colour.
                        if (self.stroke) |sw| {
                            r.strokedText(ix, iy, t.size, fg_now, fit.bytes, sw, tclip);
                            if (fit.ellipsis) r.strokedText(ix + fit.width, iy, t.size, fg_now, ellipsis, sw, tclip);
                        } else {
                            r.text(ix, iy, t.size, fg_now, fit.bytes, tclip);
                            if (fit.ellipsis) r.text(ix + fit.width, iy, t.size, fg_now, ellipsis, tclip);
                        }
                    } else {
                        var buf: [max_lines][]const u8 = undefined;
                        const n = r.wrapText(t.bytes, t.size, iw, &buf);
                        const ts = r.measureTextFace(t.bytes, t.size, t.face);
                        for (buf[0..n], 0..) |line, i| {
                            if (line.len == 0) continue;
                            const ly = iy + @as(f32, @floatFromInt(i)) * ts.line_height;
                            if (text_halo_now) |hs| r.textHalo(ix, ly, t.size, hs, line, tclip);
                            if (border_now) |bf| r.borderedText(ix, ly, t.size, bf, line, bw_i, tclip);
                            if (self.stroke) |sw| {
                                r.strokedText(ix, ly, t.size, fg_now, line, sw, tclip);
                            } else {
                                r.text(ix, ly, t.size, fg_now, line, tclip);
                            }
                        }
                    }
                },

                .button => |b| {
                    // No fill here: `fill_now` above already drew it, with
                    // hover and press substituted in. This arm is content only.
                    const ts = r.measureText(b.label, b.size);
                    r.text(
                        rect.x + (rect.w - ts.width) / 2,
                        rect.y + (rect.h - ts.height) / 2,
                        b.size,
                        fg_now,
                        b.label,
                        clip,
                    );
                },

                .bar => |b| {
                    // Track came from `fill_now`; only the value overlay here.
                    //
                    // ROUNDED, not a quad. A quad ignores `radius`, so a bar
                    // with one square end and one round end was the visible
                    // result: the track was drawn as an rrect and the overlay
                    // as a rectangle on top of it, covering the left corners.
                    var fill = rect;
                    fill.w = rect.w * std.math.clamp(b.value, 0, 1);
                    r.vtable.rrect(r.ptr, fill, self.radius, self.style().colorFill(.{ .solid = th.accent }).?, null, clip);
                },

                .rect => {},

                .icon => |ic| {
                    // No opacity or hover response of its own: an icon is
                    // decoration inside whatever draws it, and a disabled one is
                    // dimmed by the caller choosing a different `col`.
                    r.vtable.blit_svg(r.ptr, rect, ic.path, ic.col, clip);
                },

                .image => |im| {
                    // No opacity or hover either, and no tint: an image is drawn
                    // as decoded. The box is already the right shape -- `measure`
                    // used the header-derived aspect -- so paint only blits.
                    r.vtable.blit_image(r.ptr, rect, im.path, im.fit, clip);
                },

                .column => |c| {
                    if (child_clip.isEmpty()) return;
                    const inner_w = (self.width orelse rect.w) - 2 * self.pad;
                    const inner: Rect = .{
                        .x = rect.x + self.pad,
                        .y = rect.y + self.pad,
                        .w = inner_w,
                        .h = (self.height orelse rect.h) - 2 * self.pad,
                    };
                    // BOTH AXES, and no declaration of any kind.
                    const content = columnContent(r, c.children, self.gap, inner_w);
                    const sfit = self.scrollFit(inner, child_clip, content.w, content.h);
                    try self.scrollChrome(r, th, inner, sfit, content.w, content.h, hits, gpa, generic_at);
                    var y = rect.y + self.pad - sfit.off_y;
                    for (c.children, 0..) |ch, i| {
                        if (i > 0) y += self.gap;
                        y += ch.margin_top;
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, inner_w);
                        // Cross-axis: the margin is taken off the width, so the
                        // child cannot paint over the space it asked to reserve.
                        // When the column scrolls SIDEWAYS the child keeps its
                        // natural width -- squeezing it is what hid the overflow.
                        const w = if (sfit.max_x > 0)
                            @max(0, (ch.width orelse cs.w) - ch.margin_left - ch.margin_right)
                        else
                            @max(0, (ch.width orelse inner_w) - ch.margin_left - ch.margin_right);
                        try ch.paint(
                            r,
                            .{ .x = rect.x + self.pad - sfit.off_x + ch.margin_left, .y = y, .w = w, .h = cs.h },
                            sfit.vp,
                            ptr,
                            hits,
                            gpa,
                            hov,
                            th,
                        );
                        y += cs.h;
                        y += ch.margin_bottom;
                    }
                },

                .row => |c| {
                    if (child_clip.isEmpty()) return;
                    var x: f32 = undefined;
                    const inner_h = (self.height orelse rect.h) - 2 * self.pad;
                    const avail_w = (self.width orelse rect.w) - 2 * self.pad;
                    // Same totals `measure` used, so paint places children where
                    // they were measured. Recomputing is the price of `measure`
                    // taking no allocator: per-child extents cannot be held
                    // anywhere between here and there.
                    const fit = rowFit(r, c.children, self.gap, avail_w);
                    // Same rule, other axis -- and BOTH axes, because a row can
                    // be squeezed vertically just as a column can be sideways.
                    // Horizontally it overflows only when even the children's
                    // FLOORS do not fit, because a row squeezes first.
                    const inner: Rect = .{
                        .x = rect.x + self.pad,
                        .y = rect.y + self.pad,
                        .w = avail_w,
                        .h = inner_h,
                    };
                    const content_w = @max(fit.inner, fit.total_min);
                    const content_h = rowContentHeight(r, c.children, avail_w, inner_h);
                    const sfit = self.scrollFit(inner, child_clip, content_w, content_h);
                    try self.scrollChrome(r, th, inner, sfit, content_w, content_h, hits, gpa, generic_at);
                    x = rect.x + self.pad - sfit.off_x;
                    // Same pre-pass `measure` runs, for the same reason: the
                    // common baseline is the deepest child's, so placement
                    // cannot begin until every child's has been found. Both
                    // arms call `textBaseline` with the height each child will
                    // PAINT at, which is what keeps a stretched button's label
                    // and a loose caption on one line.
                    var max_base: f32 = 0;
                    if (self.row_align == .baseline) {
                        for (c.children) |ch| {
                            const cs = ch.measure(r, avail_w);
                            const w0 = rowWidth(cs, ch, fit);
                            const at = if (w0 < cs.w) ch.measure(r, w0) else cs;
                            const b = ch.textBaseline(r, w0, at.h) orelse at.h;
                            max_base = @max(max_base, b);
                        }
                    }
                    for (c.children, 0..) |ch, i| {
                        if (i > 0) x += self.gap;
                        x += ch.margin_left;
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, avail_w);
                        const w = rowWidth(cs, ch, fit);
                        // Measured again only when the placement actually needs
                        // it: `stretch` paints the full height regardless, and
                        // an extra measure per child per frame is not free.
                        // The slot a child is aligned inside: the row's inner
                        // box minus its cross-axis margins.
                        const slot_y = rect.y + self.pad + ch.margin_top;
                        const slot_h = @max(0, inner_h - ch.margin_top - ch.margin_bottom);
                        const ch_h: f32 = if (self.row_align == .stretch and sfit.max_y == 0) slot_h else blk_h: {
                            const at = if (w < cs.w) ch.measure(r, w) else cs;
                            break :blk_h at.h;
                        };
                        const y = switch (self.row_align) {
                            .center => slot_y + @max(0, (slot_h - ch_h) * 0.5),
                            .baseline => blk_b: {
                                const b = ch.textBaseline(r, w, ch_h) orelse ch_h;
                                break :blk_b slot_y + (max_base - ch.margin_top - b);
                            },
                            .stretch, .start => slot_y,
                        };
                        try ch.paint(r, .{ .x = x, .y = y, .w = w, .h = ch_h }, sfit.vp, ptr, hits, gpa, hov, th);
                        x += w;
                        x += ch.margin_right;
                    }
                },

                .stack => |c| {
                    if (child_clip.isEmpty()) return;
                    const avail_w = (self.width orelse rect.w) - 2 * self.pad;
                    // Children are NOT clipped to the stack's own box unless it
                    // sets `clips`. That is the point: a dropdown has to be able
                    // to paint past the row that triggered it. They are still
                    // confined to the inherited clip, so nothing escapes the
                    // window or an ancestor that clips.
                    //
                    // A zero-height stack is the overlay idiom: it takes no
                    // space in the flow around it, and its children still paint
                    // and still claim the pointer, because a child's height
                    // comes from its own measure and never from the stack.
                    // A stack overflows too, and it is what overlays are built
                    // from, so it gets the same rule as the rest.
                    const inner: Rect = .{
                        .x = rect.x + self.pad,
                        .y = rect.y + self.pad,
                        .w = avail_w,
                        .h = (self.height orelse rect.h) - 2 * self.pad,
                    };
                    var sw: f32 = 0;
                    var sh: f32 = 0;
                    for (c.children) |ch| {
                        const cs0 = ch.measure(r, avail_w);
                        sw = @max(sw, ch.offset[0] + (ch.width orelse cs0.w));
                        sh = @max(sh, ch.offset[1] + cs0.h);
                    }
                    const sfit = self.scrollFit(inner, child_clip, sw, sh);
                    try self.scrollChrome(r, th, inner, sfit, sw, sh, hits, gpa, generic_at);
                    for (c.children) |ch| {
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, avail_w);
                        const w = ch.width orelse cs.w;
                        try ch.paint(
                            r,
                            .{
                                .x = rect.x + self.pad + ch.offset[0],
                                .y = rect.y + self.pad + ch.offset[1],
                                .w = w,
                                .h = cs.h,
                            },
                            child_clip,
                            ptr,
                            hits,
                            gpa,
                            hov,
                            th,
                        );
                    }
                },

                .scroll => |c| {
                    if (child_clip.isEmpty()) return;
                    const inner: Rect = .{
                        .x = rect.x + self.pad,
                        .y = rect.y + self.pad,
                        .w = rect.w - 2 * self.pad,
                        .h = rect.h - 2 * self.pad,
                    };
                    if (inner.w <= 0 or inner.h <= 0) return;
                    const cs = c.child.measure(r, inner.w);
                    // Clamped HERE and nowhere else: layout is the only place
                    // that knows the content height, so a stored offset past
                    // the end is the store being one frame ahead, not a bug --
                    // and clamping on read is what stops it painting blank
                    // space at the bottom.
                    const max_off = @max(0, cs.h - inner.h);
                    const off = std.math.clamp(self.scroll_offset, 0, max_off);
                    const vp: Rect = inner.intersect(child_clip);
                    if (vp.isEmpty()) return;
                    // Recorded BEFORE the child paints, so the viewport is
                    // BELOW everything inside it in the hit list and a control
                    // in the content still wins the pointer. Recorded with no
                    // message: scrolling produces an offset, not a Msg.
                    if (self.key) |k| {
                        // Everything the generic region would have carried
                        // rides here instead, because this region IS the
                        // element's identity now: its message, whether a press
                        // still counts, and whether Tab may land on it.
                        try hits.append(gpa, .{
                            .rect = inner,
                            .clip = vp,
                            .msg = self.on_press,
                            .key = k,
                            .active = !self.disabled,
                            .focusable = self.focusable,
                            .scroll = .{ .content_h = cs.h, .view_h = inner.h },
                        });
                    }
                    try c.child.paint(
                        r,
                        .{ .x = inner.x, .y = inner.y - off, .w = inner.w, .h = cs.h },
                        vp,
                        ptr,
                        hits,
                        gpa,
                        hov,
                        th,
                    );
                    // Decoration, painted last so content can never cover it,
                    // and only when there is something to scroll.
                    if (max_off > 0 and inner.w > 2 * scrollbar_w) {
                        const track = inner.h;
                        const thumb_h = @min(track, @max(scrollbar_min_thumb, track * (track / cs.h)));
                        const ty = inner.y + (track - thumb_h) * (off / max_off);
                        r.quad(
                            .{ .x = inner.x + inner.w - scrollbar_w, .y = ty, .w = scrollbar_w, .h = thumb_h },
                            .{ .solid = th.border },
                            vp,
                        );
                        // The thumb is DRAGGABLE, and it has to be: a strip in
                        // front of the content that ignores the pointer is
                        // dead weight, and one that swallows the whole region
                        // makes the content unreachable. So it claims exactly
                        // where it is painted, with a grab area wider than the
                        // 6px it draws. Appended last, so it is the topmost
                        // region in its own viewport.
                        if (self.key) |k| {
                            const grab_w = @min(inner.w, scrollbar_grab);
                            try hits.append(gpa, .{
                                .rect = .{
                                    .x = inner.x + inner.w - grab_w,
                                    .y = ty,
                                    .w = grab_w,
                                    .h = thumb_h,
                                },
                                .clip = vp,
                                .active = !self.disabled,
                                .drag = .{ .thumb = .{ .key = k, .view = .{ .content_h = cs.h, .view_h = inner.h } } },
                            });
                        }
                    }
                },
            }
            // A widget's CONTENT, drawn after its box. The box itself is the
            // element's own `geometry`, which is exactly why a widget may not
            // add a variant there -- this is the one place its payload paints,
            // and every arm is listed so a new widget variant is a build error
            // rather than a control that draws nothing.
            if (self.widget) |wp| {
                const field_focused = hov.focus != null and self.key != null and hov.focus.? == self.key.?;
                switch (wp.*) {
                    .input => |ti| {
                        const pad = ti.pad;
                        const inner: Rect = .{
                            .x = rect.x + pad,
                            .y = rect.y + pad,
                            .w = rect.w - 2 * pad,
                            .h = rect.h - 2 * pad,
                        };
                        if (inner.w <= 0 or inner.h <= 0) return;
                        // Same rule as every other container: measure the
                        // content, let `scrollFit` decide, paint shifted by the
                        // clamped offset. A field with no `height` is measured
                        // to fit, so it never scrolls.
                        const ch = inputContentHeight(r, ti, inner.w);
                        const f = self.scrollFit(inner, clip, inner.w, ch);
                        // Always clip to the field's own box: a field with a fixed height
                        // overflows whether or not the offset has moved yet, and
                        // `scrollFit`'s no-overflow branch hands back the
                        // inherited clip rather than `inner`.
                        paintInput(r, th, ti, rect, field_focused, hov, f.off_y, inner.intersect(clip));
                        try self.scrollChrome(r, th, inner, f, inner.w, ch, hits, gpa, generic_at);
                    },
                    .slider, .select, .menu, .toast => {},
                }
            }
        }
    };
}

// ---------------------------------------------------------------------------
// builders — the `view` DSL
// ---------------------------------------------------------------------------

const widgets = @import("widgets.zig");

/// The text-editing state machine.
const reducer = @import("reducer.zig");
pub const TextEdit = reducer.TextEdit;

/// Storage for the `.vars` tier, in bytes.
pub const VarSlot = struct {
    bytes: [256]u8 align(16) = undefined,
    len: u16 = 0,
};

pub fn Ui(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Elem = Element(M);

        arena: std.heap.ArenaAllocator,
        theme: Theme = .{},
        /// Per-role gradient overrides from the theme file. Empty means every role paints
        /// its flat colour, which is the default look.
        gradients: Gradients = .{},
        /// The `.vars` tier, in BYTES. `Ui` is generic over the message type, but the
        /// tier's type is the APP's, so it cannot be a field here.
        vars_bytes: [256]u8 align(16) = undefined,
        vars_len: u16 = 0,
        /// Where the `.vars` tier lands.
        vars_slot: VarSlot = .{},
        /// Which key holds focus, mirrored from the runtime before `view` runs.
        focus: ?u64 = null,
        /// Seconds since the runtime started, mirrored before `view` runs.
        elapsed: f32 = 0,
        /// Seconds since the last key or text event.
        since_input: f32 = 0,
        /// How long the pointer has rested on the current region, reset when it moves to a
        /// different one.
        hover_since: f32 = 0,
        /// The READ side of the scroll store: whatever the runtime is holding for each
        /// keyed viewport.
        scrolls: []const ScrollSlot = &.{},
        /// set when an allocation failed. The frame is then structurally degraded rather
        /// than aborted, which is what lets `view` be infallible.
        failed: bool = false,
        /// The face the next recorded text prim draws in.
        cur_face: u16 = 0,
        /// Turns a font NAME into the face index paint wants, or null when the name cannot
        /// be produced.
        face_lookup: ?*const FaceLookup = null,
        /// The theme files' named styles, for `style`. Points into the chain, which
        /// outlives the frame; null when the app loaded no theme.
        styles: ?[]const StyleEntry = default_styles,

        /// which failure `failed` refers to; only meaningful when failed
        fail_kind: FailKind = .layout_allocation,
        /// Detail for the band, formatted in place.
        fail_buf: [192]u8 = undefined,
        fail_len: usize = 0,

        /// A failure raised from outside a build; see `failExternal`. Zero length means
        /// none, and that is the whole state.
        ext_kind: FailKind = .theme,
        ext_buf: [192]u8 = undefined,
        ext_len: usize = 0,
        /// stands in for any node that could not be allocated
        dead: Elem,

        /// Resolves a font name to the index `Style.face` wants.
        pub fn font(self: *const Self, name: []const u8) ?u16 {
            const l = self.face_lookup orelse return null;
            return l.resolve(l.ptr, name);
        }

        /// Resolve a named style from the theme files into the values an element wants, or
        /// null when the theme names no such style.
        pub fn vars(self: *const Self, comptime T: type) T {
            // Oversize is a compile error here too, for the same reason as
            // `setVars`: the buffer can never hold this type, so returning
            // defaults is a silent lie rather than a "nothing written yet".
            // The `vars_len` check BELOW stays silent on purpose -- that is the
            // documented first-frame behaviour, not a failure.
            comptime {
                if (@sizeOf(T) > @sizeOf([256]u8)) @compileError(std.fmt.comptimePrint(
                    "theme_tokens: {s} is {d} bytes, over the {d}-byte vars buffer",
                    .{ @typeName(T), @sizeOf(T), @sizeOf([256]u8) },
                ));
            }
            if (self.vars_len != @sizeOf(T)) return .{};
            var out: T = undefined;
            @memcpy(std.mem.asBytes(&out), self.vars_bytes[0..@sizeOf(T)]);
            return out;
        }

        /// Write the tier.
        pub fn setVars(self: *Self, comptime T: type, value: T) void {
            // A type too large for the buffer is a COMPILE error, not a quiet
            // no-op. Returning early here was silent in the worst way: the write
            // was skipped, `vars_len` stayed 0, `vars()` kept handing back the
            // defaults, and the app looked like the file had been ignored --
            // indistinguishable from a typo in the theme itself. The type is
            // known at comptime, so refuse it there instead.
            //
            // Grow `vars_bytes` if an app legitimately needs more; the limit is
            // a fixed buffer, not a design boundary.
            comptime {
                if (@sizeOf(T) > @sizeOf([256]u8)) @compileError(std.fmt.comptimePrint(
                    "theme_tokens: {s} is {d} bytes, over the {d}-byte vars buffer",
                    .{ @typeName(T), @sizeOf(T), @sizeOf([256]u8) },
                ));
            }
            @memcpy(self.vars_bytes[0..@sizeOf(T)], std.mem.asBytes(&value));
            self.vars_len = @sizeOf(T);
        }

        pub fn roleFill(self: *const Self, name: []const u8) Fill {
            if (self.gradients.get(name)) |g| return g;
            return .{ .solid = roleColor(self.theme, name) };
        }

        pub fn styleByName(self: *const Self, name: []const u8) ?Style {
            const styles = self.styles orelse return null;
            for (styles) |entry| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                var out: Style = .{};
                // A role reference is resolved against THIS frame's palette,
                // so editing `.colors` moves every style that names it.
                if (entry.spec.bg) |r| out.bg = self.roleFill(r);
                if (entry.spec.color) |r| out.color = self.roleFill(r);
                if (entry.spec.border) |r| out.border = self.roleFill(r);
                out.border_width = entry.spec.border_width;
                if (entry.spec.font) |f| out.face = self.font(f);
                out.size = entry.spec.size;
                out.weight = entry.spec.weight;
                if (entry.spec.frost) |f| out.frost = .{ .blur = f.blur };
                out.stroke = entry.spec.stroke;
                if (entry.spec.halo) |h| out.halo = .{
                    .color = roleColor(self.theme, h.color),
                    .blur = h.blur,
                    .spread = h.spread,
                    .offset = h.offset,
                    .light = h.light,
                    .mode = h.mode,
                    .quality = h.quality,
                };
                return out;
            }
            return null;
        }

        /// Current offset for a keyed viewport, or 0 if it has never moved.
        pub fn scrollAt(self: *const Self, key: ?u64) f32 {
            const k = key orelse return 0;
            for (self.scrolls) |s| {
                if (s.key == k) return s.offset;
            }
            return 0;
        }

        pub fn init(gpa: Allocator) Self {
            return .{
                .arena = .init(gpa),
                .dead = .{ .geometry = .{ .rect = {} } },
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Drops every node from the previous frame, keeping the arena's pages.
        pub fn reset(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
        }

        /// Merge a named theme style onto `e`, or REPORT the miss. A name the theme does
        /// not have used to resolve to null and merge nothing, so the element painted the
        /// compiled floor with no diagnostic -- the same silent-drop class as `.halo`
        /// vanishing. `where` names the path the name came in through.
        fn applyNamed(self: *Self, e: *Elem, nm: []const u8, comptime where: []const u8) void {
            if (self.styleByName(nm)) |named| {
                e.mergeStyle(named);
            } else {
                self.noteMiss(nm, where);
            }
        }

        /// The ONE resolution order, as a value: the inline tuple's own `.name`/`.class`
        /// first, then its fields. Builders that need a style field BEFORE the Element
        /// exists (text needs `size` for geometry) call this instead of duplicating the
        /// walk. There is exactly one spelling -- `.style = .{ .name = "x" }` -- because
        /// a second, bare name field made two spellings for one job and no way to tell
        /// which a call site meant.
        fn resolveStyle(self: *Self, o: anytype) Style {
            var out: Style = .{};
            const given: Style = fieldOr(o, "style", Style{});
            if (given.refName()) |nm| {
                if (self.styleByName(nm)) |n| out.merge(n) else self.noteMiss(nm, "style.name");
            }
            out.merge(given);
            return out;
        }

        /// Raise the band for a style name the theme does not define.
        fn noteMiss(self: *Self, nm: []const u8, comptime where: []const u8) void {
            self.failFmt(.style, where ++ " names \"{s}\", which no theme style defines", .{nm});
        }

        /// Records a failure that has no detail beyond its kind.
        pub fn failWith(self: *Self, kind: FailKind) void {
            self.failed = true;
            self.fail_kind = kind;
            self.fail_len = 0;
        }

        /// Records a failure and formats the explanation into the band's own buffer.
        pub fn failFmt(self: *Self, kind: FailKind, comptime f: []const u8, args: anytype) void {
            self.failed = true;
            self.fail_kind = kind;
            // Truncation is fine here: the band is one line, and a message
            // that long is a diagnostic nobody could read in it anyway.
            const written = std.fmt.bufPrint(&self.fail_buf, f, args) catch self.fail_buf[0..];
            self.fail_len = written.len;
        }

        /// Raise a failure that OUTLIVES the next frame reset.
        pub fn failExternal(self: *Self, kind: FailKind, comptime f: []const u8, args: anytype) void {
            self.ext_kind = kind;
            const written = std.fmt.bufPrint(&self.ext_buf, f, args) catch self.ext_buf[0..];
            self.ext_len = written.len;
        }

        /// The outside world recovered. Nothing else clears this, because nothing outside
        /// the caller knows the condition is gone.
        pub fn clearExternal(self: *Self) void {
            self.ext_len = 0;
        }

        /// What the band paints: the formatted detail when there is one, the kind's own
        /// text otherwise.
        pub fn failMessage(self: *const Self) []const u8 {
            if (self.fail_len == 0) return self.fail_kind.message();
            return self.fail_buf[0..self.fail_len];
        }

        /// The frame arena, for `widgets.zig`.
        pub fn alloc(self: *Self) Allocator {
            return self.arena.allocator();
        }

        /// Put a widget payload in the FRAME ARENA and hand back a pointer.
        pub fn payload(self: *Self, w: Widget(M)) ?*const Widget(M) {
            const p = self.alloc().create(Widget(M)) catch {
                self.failWith(.layout_allocation);
                return null;
            };
            p.* = w;
            return p;
        }

        fn mk(self: *Self, geometry: Elem.Geometry) *Elem {
            const e = self.alloc().create(Elem) catch {
                self.failWith(.layout_allocation);
                return &self.dead;
            };
            e.* = .{ .geometry = geometry };
            return e;
        }

        fn dupeKids(self: *Self, items: []const *Elem) []const *Elem {
            return self.alloc().dupe(*Elem, items) catch {
                self.failWith(.layout_allocation);
                return &.{};
            };
        }

        /// Which of the two text roles a label uses.
        pub const Tone = enum { normal, muted };

        /// What every builder accepts, repeated in each opts struct rather than shared
        /// through a nested field.
        fn finish(self: *Self, e: *Elem, o: anytype) *Elem {
            // Every margin an options struct happens to offer is applied.
            // @hasField rather than a required set: a builder that never wants
            // margins should not have to declare four zeroes to say so.
            inline for (.{ "margin_left", "margin_right", "margin_top", "margin_bottom" }) |m| {
                if (@hasField(@TypeOf(o), m)) @field(e, m) += @field(o, m);
            }
            // Probed, not assumed: `finish` serves every builder, and not all
            // of them declare the same fields.
            if (fieldOr(o, "key", @as(?u64, null))) |k| e.key = k;
            if (fieldOr(o, "disabled", false)) e.disabled = true;
            // Any element is pressable once it carries a message; that is the
            // generic hit path, not a button privilege. Buttons pass it in as
            // `msg`, everything else through this.
            if (fieldOr(o, "on_press", @as(?M, null))) |msg| e.on_press = msg;
            if (fieldOr(o, "clips", false)) e.clips = true;
            if (fieldOr(o, "hover", @as(?Fill, null))) |v| e.hover = v;
            if (fieldOr(o, "hover_halo", @as(?Halo, null))) |v| e.hover_halo = v;
            if (fieldOr(o, "pressed", @as(?Fill, null))) |v| e.pressed = v;
            // Precedence, least specific first: a named style via `.{ .name = "x" }`
            // supplies the base, and inline fields override it field by field.
            const style: Style = fieldOr(o, "style", Style{});
            if (style.refName()) |nm| {
                self.applyNamed(e, nm, "style.name");
            }
            // Caller last: a caller who set a field meant it, and `mergeStyle`
            // writes only the fields they actually set.
            e.mergeStyle(style);
            // A text element also carries its face inside the geometry, which is
            // what paint reads. Copied here rather than in `text()` because the
            // style arrives last: `text()` runs before `finish` merges it, so a
            // face set at build time would be overwritten by the default.
            const st = e.style();
            if (st.face) |f| switch (e.geometry) {
                .text => |*tx| tx.face = f,
                else => {},
            };
            // Same rule for the weight: it belongs to the face, and paint
            // reads both off the geometry.
            if (st.weight) |v| switch (e.geometry) {
                .text => |*tx| tx.weight = v,
                else => {},
            };
            return e;
        }

        pub const TextOpts = struct {
            label: []const u8,
            /// Optional so a STYLE can supply it: a non-optional default of 14 meant every
            /// call site silently asked for 14, and a theme's `.size` could never win.
            size: ?f32 = null,
            /// The typeface to draw this label in, BY NAME, resolved through the runtime's
            /// registry.
            font: ?[]const u8 = null,
            tone: Tone = .normal,
            wrap: bool = false,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over the element.
            hover_halo: ?Halo = null,
            width: ?f32 = null,
            height: ?f32 = null,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            key: ?u64 = null,
            disabled: bool = false,
            clips: bool = false,
        };

        pub const ColumnOpts = struct {
            children: []const *Elem,
            gap: f32 = 0,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over the element.
            hover_halo: ?Halo = null,
            width: ?f32 = null,
            height: ?f32 = null,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            key: ?u64 = null,
            disabled: bool = false,
            clips: bool = false,
        };

        /// A row is a column with the axis swapped: identical options, and keeping them one
        /// declaration means a new field lands in both.
        pub const RowOpts = ColumnOpts;

        pub const ButtonOpts = struct {
            label: []const u8,
            msg: M,
            size: f32 = 16,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over the element.
            hover_halo: ?Halo = null,
            width: ?f32 = null,
            height: ?f32 = null,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            key: ?u64 = null,
            disabled: bool = false,
            clips: bool = false,
        };

        pub const BarOpts = struct {
            value: f32,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over the element.
            hover_halo: ?Halo = null,
            width: ?f32 = null,
            height: ?f32 = null,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            key: ?u64 = null,
            disabled: bool = false,
            clips: bool = false,
        };

        pub const RectOpts = struct {
            width: f32,
            height: f32,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over the element.
            hover_halo: ?Halo = null,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            key: ?u64 = null,
            disabled: bool = false,
            clips: bool = false,
        };

        pub fn column(self: *Self, o: ColumnOpts) *Elem {
            const e = self.mk(.{ .column = .{ .children = self.dupeKids(o.children) } });
            e.gap = o.gap;
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            return self.finish(e, o);
        }

        pub fn row(self: *Self, o: RowOpts) *Elem {
            const e = self.mk(.{ .row = .{ .children = self.dupeKids(o.children) } });
            e.gap = o.gap;
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            return self.finish(e, o);
        }

        /// Same options as a column; `gap` is meaningless and ignored, because no two stack
        /// children are adjacent.
        pub const StackOpts = ColumnOpts;

        /// Children share an origin and may overlap. See `Geometry.stack`.
        pub fn stack(self: *Self, o: StackOpts) *Elem {
            const e = self.mk(.{ .stack = .{ .children = self.dupeKids(o.children) } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            return self.finish(e, o);
        }

        pub const ScrollOpts = struct {
            child: *Elem,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            hover_halo: ?Halo = null,
            width: ?f32 = null,
            /// The viewport's height.
            height: ?f32 = null,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            /// Required for a scrollable viewport: the offset is stored under this key, so
            /// an unkeyed viewport sits at zero forever.
            key: ?u64 = null,
            disabled: bool = false,
            /// accepted and redundant: a viewport always clips.
            clips: bool = false,
        };

        /// A viewport over one child.
        pub fn scroll(self: *Self, o: ScrollOpts) *Elem {
            const e = self.mk(.{ .scroll = .{ .child = o.child } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.clips = true;
            return self.finish(e, o);
        }

        /// Text. `color` is only set for `tone = .muted`: leaving it unset is the paint
        /// default, so the common case writes one fewer field.
        pub fn text(self: *Self, o: TextOpts) *Elem {
            // Precedence, one place: an explicit call-site size wins, then the
            // style the element carries, then the widget default. The style is
            // read here rather than in `finish` because `size` is a field of
            // the geometry, and finish runs after it was already recorded.
            // A named theme style is resolved HERE as well as in `finish`, because
            // `size` and `weight` are fields of the text geometry and finish runs
            // after the geometry was recorded. Resolving both places is what makes
            // a named style work for text at all.
            // Same order as `finish`, built once so the two cannot drift: the inline
            // tuple's `.name`/`.class` supplies the base, its fields override it.
            // Reported once here, not twice: `finish` would re-resolve the same names
            // and raise the same miss again, and the band holds one line.
            const merged = self.resolveStyle(o);
            const size: f32 = o.size orelse (merged.size orelse 14);
            const weight: u16 = merged.weight orelse 0;
            const e = self.mk(.{ .text = .{
                .bytes = o.label,
                .size = size,
                .weight = weight,
            } });
            // The ONLY place a name becomes a face. `font` returns an opaque
            // handle; nothing downstream can forge one.
            if (o.font) |n| e.face = self.font(n) orelse 0;
            e.wrap = o.wrap;
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            if (o.tone == .muted) e.color = .{ .solid = self.theme.text_muted };
            return self.finish(e, o);
        }

        /// Format into the frame arena and hand back the slice.
        pub fn fmt(self: *Self, comptime f: []const u8, args: anytype) []const u8 {
            return std.fmt.allocPrint(self.alloc(), f, args) catch {
                self.failWith(.layout_allocation);
                return "";
            };
        }

        pub fn button(self: *Self, o: ButtonOpts) *Elem {
            const e = self.mk(.{ .button = .{ .label = o.label, .size = o.size } });
            // The click is an element fact, not a button fact: the generic
            // `on_press` hit path already registers it, so the button geometry
            // does not need to carry the message as well.
            e.on_press = o.msg;
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.hover = .{ .solid = self.theme.hover };
            e.pressed = .{ .solid = self.theme.pressed };
            // The geometry's own look, then the caller's overlay.
            e.applyStyle(.{ .bg = .{ .solid = self.theme.control }, .color = .{ .solid = self.theme.text } });
            return self.finish(e, o);
        }

        pub fn bar(self: *Self, o: BarOpts) *Elem {
            const e = self.mk(.{ .bar = .{ .value = o.value } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.applyStyle(.{ .bg = .{ .solid = self.theme.control }, .color = .{ .solid = self.theme.accent } });
            return self.finish(e, o);
        }

        pub const ImageOpts = struct {
            /// Where the encoded image lives. Read once and cached by path; a
            /// path that does not decode draws nothing rather than failing the
            /// frame.
            path: []const u8,
            /// `.fit` keeps the source aspect (the element is already shaped
            /// correctly by `measure`, so this is normally a plain fill);
            /// `.stretch` fills the box even when that distorts.
            fit: ImageFit = .fit,
            /// Both null means "take the available width, height from the
            /// aspect". Set `height` with a width to force a box, which `.fit`
            /// will then letterbox inside.
            width: ?f32 = null,
            height: ?f32 = null,
            on_press: ?M = null,
        };

        pub const IconOpts = struct {
            /// Where the SVG file lives. Read once per (path, size, density,
            /// colour) and cached after; a path that does not read draws
            /// nothing rather than failing the frame.
            path: []const u8,
            /// Tint. Every path in the file is filled this colour, so an icon
            /// is one colour -- a multi-colour logo will come out flat.
            color: Fill = .{ .solid = .{ .r = 255, .g = 255, .b = 255 } },
            /// null means the square 24x24 default. Set these for a different
            /// aspect; there is no intrinsic size to fall back on.
            width: ?f32 = null,
            height: ?f32 = null,
            on_press: ?M = null,
            hover: ?Fill = null,
            pressed: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over the element.
            hover_halo: ?Halo = null,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            key: ?u64 = null,
            disabled: bool = false,
            clips: bool = false,
        };

        /// A raster image, drawn as decoded.
        ///
        /// Takes its SHAPE from the file: `measure` reads the header and gives
        /// the element the image's aspect, so a portrait photo is tall without
        /// the caller knowing. Set `width` to pin the width; height follows.
        ///
        /// An unreadable path measures square and paints nothing. That is
        /// deliberate -- a broken image should not fail a layout pass.
        pub fn image(self: *Self, o: ImageOpts) *Elem {
            const e = self.mk(.{ .image = .{ .path = o.path, .fit = o.fit } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.on_press = o.on_press;
            return self.finish(e, o);
        }

        pub fn icon(self: *Self, o: IconOpts) *Elem {
            // The tint is flattened HERE, at build time. The cache keys on RGB,
            // so resolving a fill per frame would mean comparing colours the
            // widget layer never settles on; a gradient or a role collapses to
            // its representative colour once and stays put.
            // A GRADIENT IS FLATTENED, not refused: the raster is tinted one
            // colour, and taking the first stop means an icon styled from the
            // same `Fill` as a button does not have to be special-cased by the
            // caller. The alternative -- silently drawing black -- is worse.
            const rgb: Color = switch (o.color) {
                .solid => |c| c,
                .linear => |l| l.stops.colors[0],
                .radial => |r| r.stops.colors[0],
            };
            const e = self.mk(.{ .icon = .{ .path = o.path, .col = .{ rgb.r, rgb.g, rgb.b } } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.on_press = o.on_press;
            return self.finish(e, o);
        }

        /// A rule between things: decoration, so no key, no message and no focus. Anything
        /// clickable is a control, not this.
        pub const SeparatorOpts = struct {
            vertical: bool = false,
            /// Whole pixels: at 1.5 density a 1px rule is already the thinnest line that
            /// draws without going soft.
            thickness: f32 = 1,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
        };

        pub fn separator(self: *Self, o: SeparatorOpts) *Elem {
            const t = @max(1.0, o.thickness);
            // `rect` resolves `.style` through `finish`, so the caller's
            // style is forwarded rather than dropped. The border colour stays in as the
            // DEFAULT fill, which is what an unstyled rule should be -- a caller who
            // sets `.bg` overrides just that, and everything else (radius, halo, a
            // named style) still arrives.
            // The caller's style goes in WITH the default, in one tuple: `rect` merges
            // the named style first and these fields over it, so a caller who sets
            // `.bg` beats the theme border and one who does not still gets it.
            var st = o.style;
            if (st.bg == null) st.bg = .{ .solid = self.theme.border };
            const e = self.rect(.{
                .width = t,
                .height = t,
                .style = st,
            });
            // The CROSS axis stretches. An unset extent is what both a column's
            // child and a row's child read as "fill the slot you were given", so
            // clearing one side here is the whole of the orientation.
            if (o.vertical) e.height = null else e.width = null;
            e.margin_left = o.margin_left;
            e.margin_right = o.margin_right;
            e.margin_top = o.margin_top;
            e.margin_bottom = o.margin_bottom;
            return e;
        }

        /// Determinate only. An indeterminate bar is an animation, and this widget would
        /// then need the frame clock to mean anything at all.
        pub const ProgressOpts = struct {
            /// 0 to 1. Clamped, not asserted: a progress value is usually derived from data
            /// the app does not fully control.
            value: f32,
            width: ?f32 = null,
            height: f32 = 6,
            style: Style = .{},
            /// A NAMED style from the theme's `.styles` table, resolved UNDER `style`.
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
        };

        pub fn progress(self: *Self, o: ProgressOpts) *Elem {
            // NaN survives every comparison, and @min/@max keep the OTHER
            // operand, so an unguarded clamp turns NaN into 1.0 and paints a
            // full bar for a value that has no answer. Guard the input.
            const v = if (std.math.isFinite(o.value)) std.math.clamp(o.value, 0.0, 1.0) else 0.0;
            // Forwarded, not dropped: `bar` resolves the style through `finish`, so a
            // themed progress track reaches paint the same way a themed button does.
            const e = self.bar(.{
                .value = v,
                .width = o.width,
                .height = o.height,
                .style = o.style,
            });
            e.margin_left = o.margin_left;
            e.margin_right = o.margin_right;
            e.margin_top = o.margin_top;
            e.margin_bottom = o.margin_bottom;
            return e;
        }

        /// A plain sized box. Formerly you had to abuse `bar` for this.
        pub fn rect(self: *Self, o: RectOpts) *Elem {
            const e = self.mk(.rect);
            e.width = o.width;
            e.height = o.height;
            return self.finish(e, o);
        }

        pub fn slider(self: *Self, o: widgets.SliderOpts(M)) *Elem {
            return widgets.slider(self, o);
        }

        pub fn select(self: *Self, o: widgets.SelectOpts(M)) *Elem {
            return widgets.select(self, o);
        }

        pub fn input(self: *Self, o: widgets.InputOpts(M)) *Elem {
            return widgets.input(self, o);
        }

        pub fn menu(self: *Self, o: widgets.MenuOpts(M)) *Elem {
            return widgets.menu(self, o);
        }

        pub fn control(self: *Self, o: widgets.ControlOpts(M)) *Elem {
            return widgets.control(self, o);
        }

        pub fn checkbox(self: *Self, o: widgets.ControlOpts(M)) *Elem {
            return widgets.checkbox(self, o);
        }

        pub fn radio(self: *Self, o: widgets.ControlOpts(M)) *Elem {
            return widgets.radio(self, o);
        }

        pub fn toggle(self: *Self, o: widgets.ControlOpts(M)) *Elem {
            return widgets.toggle(self, o);
        }

        pub fn severityColor(self: *Self, s: Severity) Color {
            return switch (s) {
                .info => self.theme.accent,
                .success => self.theme.success,
                .warning => self.theme.warning,
                .@"error" => self.theme.fail,
            };
        }

        pub fn toast(self: *Self, o: widgets.ToastOpts(M)) *Elem {
            return widgets.toast(self, o);
        }

        /// A row's key, derived from its control's key and its index.
        pub fn rovingKey(owner: u64, index: u16) u64 {
            return owner *% 0x100000001b3 +% (@as(u64, index) +% 1);
        }

        pub fn tabs(self: *Self, o: widgets.TabsOpts(M)) *Elem {
            return widgets.tabs(self, o);
        }

        pub fn list(self: *Self, o: widgets.ListOpts(M)) *Elem {
            return widgets.list(self, o);
        }
    };
}

// ---------------------------------------------------------------------------
// frame: the output of one view+layout+paint pass
// ---------------------------------------------------------------------------

pub fn Frame(comptime M: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        prims: []Primitive,
        hits: []Hit(M),
        size: Size,

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Topmost interactive region under a point, with the geometry that claimed it.
        pub fn focusStep(self: *const Self, from: ?u64, forward: bool) ?u64 {
            var n: usize = 0;
            var at: ?usize = null;
            // Focus does not leave an open scope. `from` says where focus is,
            // and the scope it sits in is therefore the one in force -- no
            // "which dialog is open" flag to keep in step with the tree.
            const active_scope = self.scopeOf(from);
            for (self.hits) |h| {
                if (!h.focusable or !h.active) continue;
                const k = h.key orelse continue;
                if (h.scope != active_scope) continue;
                // A row of a roving control is not a stop of its own: the
                // control is, so Tab crosses a twenty-row list in one press.
                if (h.roving != null) continue;
                if (from) |f| {
                    if (f == k and at == null) at = n;
                }
                n += 1;
            }
            if (n == 0) return null;
            const want: usize = if (at) |i|
                (if (forward) (i + 1) % n else (i + n - 1) % n)
            else if (forward) 0 else n - 1;

            var i: usize = 0;
            for (self.hits) |h| {
                if (!h.focusable or !h.active) continue;
                const k = h.key orelse continue;
                if (h.scope != active_scope) continue;
                if (h.roving != null) continue;
                if (i == want) return k;
                i += 1;
            }
            return null;
        }

        pub fn hit(self: *const Self, p: [2]f32) ?Hit(M) {
            var i = self.hits.len;
            while (i > 0) {
                i -= 1;
                const h = self.hits[i];
                if (h.rect.containsRounded(h.radius, p) and h.clip.contains(p)) return if (h.active) published(M, h) else null;
            }
            return null;
        }

        /// The control payload recorded for a keyed region, valid until this frame ends.
        /// The runtime's own door: an app gets `Hit`, which never carries one.
        pub fn widgetAt(self: *const Self, key: u64) ?*const Widget(M) {
            for (self.hits) |h| {
                if (h.key) |k| {
                    if (k == key) return h.widget;
                }
            }
            return null;
        }

        /// The scope a keyed region lives in: the innermost element that declared
        /// `focus_scope`, or null at the root.
        pub fn scopeOf(self: *const Self, key: ?u64) ?u64 {
            const k = key orelse return null;
            for (self.hits) |h| {
                if (h.key) |hk| {
                    if (hk == k) return h.scope;
                }
            }
            return null;
        }

        /// One row of a roving control, as the runtime needs it: where it is in the set,
        /// and what to focus or scroll to.
        pub const Roamer = struct { index: u16, key: u64, rect: Rect };

        /// The row `delta` places from `from_index` inside the control `owner`, clamped
        /// rather than wrapped: running off the end of a list should stop.
        pub fn rovingStep(self: *const Self, owner: u64, from_index: u16, delta: i32) ?Roamer {
            var lo: ?Roamer = null;
            var hi: ?Roamer = null;
            const want: i32 = @as(i32, from_index) + delta;
            for (self.hits) |h| {
                if (h.roving) |o| {
                    if (o != owner) continue;
                    const k = h.key orelse continue;
                    const r = Roamer{ .index = h.roving_index, .key = k, .rect = h.rect };
                    // Clamp: remember the nearest row on each side of where we
                    // want to be, so moving past either end lands on the end.
                    if (r.index <= want) {
                        if (lo == null or r.index > lo.?.index) lo = r;
                    }
                    if (r.index >= want) {
                        if (hi == null or r.index < hi.?.index) hi = r;
                    }
                }
            }
            return hi orelse lo;
        }

        /// Where an arrow key moves a roving control, given the key that currently has
        /// focus.
        pub fn rovingMove(self: *const Self, from_key: ?u64, delta: i32) ?Roamer {
            const k = from_key orelse return null;
            for (self.hits) |h| {
                if (h.key != k) continue;
                if (h.roving) |owner| return self.rovingStep(owner, h.roving_index, delta);
                // The focused element is the CONTROL, not one of its rows.
                // That is the state `focusStep` always produces, because it
                // skips every row of a roving control -- so if an arrow could
                // not step in from here the rows would be unreachable by
                // keyboard entirely. Enter at the end the direction comes
                // from, so Down and Up both read as "into the list".
                return self.rovingEdge(k, delta);
            }
            return null;
        }

        /// The first row (for a downward step) or the last one (for an upward step) of the
        /// roving control `owner`.
        fn rovingEdge(self: *const Self, owner: u64, delta: i32) ?Roamer {
            var first: ?Roamer = null;
            var last: ?Roamer = null;
            for (self.hits) |h| {
                const o = h.roving orelse continue;
                if (o != owner) continue;
                const k = h.key orelse continue;
                const r = Roamer{ .index = h.roving_index, .key = k, .rect = h.rect };
                if (first == null or r.index < first.?.index) first = r;
                if (last == null or r.index > last.?.index) last = r;
            }
            return if (delta > 0) first else last;
        }

        /// The open popup that should take the keyboard, preferring one anchored on the
        /// focused element.
        pub fn openPopup(self: *const Self, prefer_key: ?u64) ?*const Widget(M) {
            var any: ?*const Widget(M) = null;
            for (self.hits) |h| {
                const w = h.widget orelse continue;
                const open = switch (w.*) {
                    .select => |sel| sel.open,
                    .menu => |mn| mn.open,
                    else => false,
                };
                if (!open) continue;
                if (prefer_key != null and h.key != null and h.key.? == prefer_key.?) return w;
                if (any == null) any = w;
            }
            return any;
        }

        /// The highlight of a popup, and the items it highlights. Split out because both
        /// arms have to agree about which list `active` indexes.
        pub const PopupRows = struct {
            items: []const Choice(M),
            active: *?u16,
        };

        pub fn popupRows(w: *const Widget(M)) ?PopupRows {
            return switch (w.*) {
                .select => |sel| .{ .items = sel.options, .active = sel.active },
                .menu => |mn| .{ .items = mn.items, .active = mn.active },
                else => null,
            };
        }

        /// Activated by the focused control, if it has one.
        pub fn activate(self: *const Self, key: ?u64) ?M {
            const k = key orelse return null;
            for (self.hits) |h| {
                if (!h.active or !h.focusable) continue;
                if (h.key) |hk| {
                    if (hk == k) return h.msg;
                }
            }
            return null;
        }

        /// Topmost interactive region under a point wins.
        pub fn hitTest(self: *const Self, p: [2]f32) ?M {
            const h = self.hit(p) orelse return null;
            return h.msg;
        }

        pub fn primitiveCount(self: *const Self) usize {
            return self.prims.len;
        }
    };
}

/// Pointer capture: one press owns the click from the moment the button goes down until it
/// comes back up.
pub fn Press(comptime M: type) type {
    return struct {
        const Self = @This();

        captured: ?Hit(M) = null,

        /// Claims the topmost region under the press, if any. Pressing empty space claims
        /// nothing, so releasing over a button later does not click it.
        pub fn down(self: *Self, f: *const Frame(M), p: [2]f32) void {
            self.captured = f.hit(p);
        }

        /// Releases the claim and yields the message, but only if the pointer comes up
        /// inside the region that was pressed.
        pub fn up(self: *Self, p: [2]f32) ?M {
            const h = self.captured orelse return null;
            self.captured = null;
            if (!h.rect.containsRounded(h.radius, p) or !h.clip.contains(p)) return null;
            return h.msg;
        }

        /// Drops the claim without producing a message, for the paths that never see a
        /// release (window lost the pointer, app is quitting).
        pub fn cancel(self: *Self) void {
            self.captured = null;
        }

        /// Re-binds a keyed claim to the element carrying the same key in a newer frame.
        pub fn rebind(self: *Self, hits: []const Hit(M)) void {
            const h = self.captured orelse return;
            if (h.key) |k| {
                // Keyed: identity decides. The element may have moved to the
                // far side of the list and the claim follows it there.
                for (hits) |nh| {
                    if (nh.key) |nk| {
                        if (nk == k) {
                            if (!nh.active) {
                                self.captured = null;
                                return;
                            }
                            self.captured = published(M, nh);
                            return;
                        }
                    }
                }
                self.captured = null; // the element is gone
                return;
            }
            // Unkeyed: geometry decides, as it always has. The rect is only
            // re-examined to notice that it went inert mid-gesture.
            for (hits) |nh| {
                if (nh.rect.eql(h.rect) and nh.clip.eql(h.clip)) {
                    if (!nh.active) self.captured = null;
                    return;
                }
            }
        }

        pub fn waiting(self: *const Self) bool {
            return self.captured != null;
        }
    };
}

/// Replays primitives into a list. Handy for tests and for backends that batch.
pub fn Collector(comptime M: type) type {
    _ = M;
    return struct {
        const Self = @This();
        gpa: Allocator,
        prims: std.ArrayList(Primitive) = .empty,
        /// Set when a primitive could not be recorded because the list could not grow.
        failed: bool = false,
        /// Where layout gets its glyph metrics.
        metrics: Renderer,
        /// The face the next recorded text prim draws in.
        cur_face: u16 = 0,
        cur_weight: u16 = 0,
        /// The halo for the NEXT text prim this collector queues. Set by
        /// `vtTextHalo` and cleared by whatever text call consumes it, so a
        /// glow and its letters are one prim and the canvas owns the order.
        pending_halo: ?Halo = null,
        /// Image dimensions the test DECLARED. The collector has no filesystem,
        /// so a test that lays out an image must say how big it is; `measure`
        /// then behaves exactly as it does against a real header, and the
        /// aspect is stable across frames by construction.
        image_dims: std.StringArrayHashMapUnmanaged([2]u32) = .empty,

        pub fn deinit(self: *Self) void {
            self.prims.deinit(self.gpa);
            self.image_dims.deinit(self.gpa);
        }

        /// Declare the intrinsic size of `path` for layout in this test.
        pub fn setImageSize(self: *Self, path: []const u8, w: u32, h: u32) !void {
            try self.image_dims.put(self.gpa, path, .{ w, h });
        }

        pub fn renderer(self: *Self) Renderer {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        const vtable = Renderer.VTable{
            .quad = vtQuad,
            .path = vtPath,
            .rrect = vtRrect,
            .text = vtText,
            .stroked_text = vtStrokedText,
            .text_halo = vtTextHalo,
            .set_face = vtSetFace,
            .set_weight = vtSetWeight,
            .halo = vtHalo,
            .frost = vtFrost,
            .measure_text = vtMeasure,
            .measure_text_face = vtMeasureFace,
            .wrap_text = vtWrap,
            .advance_text = vtAdvanceText,
            .hit_text = vtHitText,
            .blit = vtBlit,
            .blit_svg = vtBlitSvg,
            .blit_image = vtBlitImage,
            .measure_image = vtMeasureImage,
        };

        fn vtBlit(
            ptr: *anyopaque,
            rect: Rect,
            pixels: []const u8,
            src_w: u32,
            src_h: u32,
            clip: Rect,
        ) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // A blit is a real prim, not an effect on a neighbouring one: it has
            // its own pixels and its own place in the paint order.
            self.prims.append(self.gpa, .{ .blit = .{
                .rect = rect,
                .pixels = pixels,
                .src_w = src_w,
                .src_h = src_h,
                .clip = clip,
            } }) catch {
                self.failed = true;
            };
        }

        fn vtBlitSvg(ptr: *anyopaque, rect: Rect, path: []const u8, col: [3]u8, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Recorded as SOURCE, never rasterised: this collector exists to say
            // what the widget layer ASKED FOR. Whether the renderer then serves
            // it from cache is the renderer's business and is tested there.
            self.prims.append(self.gpa, .{ .icon = .{
                .rect = rect,
                .path = path,
                .col = col,
                .clip = clip,
            } }) catch {
                self.failed = true;
            };
        }

        fn vtBlitImage(ptr: *anyopaque, rect: Rect, path: []const u8, fit: ImageFit, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Source, like `vtBlitSvg`: what the widget ASKED FOR. Whether the
            // renderer serves it from cache is tested there, not here.
            self.prims.append(self.gpa, .{ .image = .{
                .rect = rect,
                .path = path,
                .fit = fit,
                .clip = clip,
            } }) catch {
                self.failed = true;
            };
        }

        fn vtMeasureImage(ptr: *anyopaque, path: []const u8) ?[2]u32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // The collector has no file access and must not gain any: a probe
            // here would make layout depend on the real filesystem, which is
            // exactly the coupling `measure` is supposed to avoid in a test.
            return self.image_dims.get(path);
        }

        fn vtMeasureFace(ptr: *anyopaque, bytes: []const u8, size: f32, face: u16) TextMetrics {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.measureTextFace(bytes, size, face);
        }

        fn vtFrost(ptr: *anyopaque, rect: Rect, radius: f32, blur: f32, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // A frost only touches its own box, so the box is the prune.
            if (rect.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .frost = .{
                .rect = rect,
                .radius = radius,
                .blur = blur,
                .clip = clip,
            } }) catch {
                self.failed = true;
            };
        }

        /// A path has no layout consequence, so the collector records nothing: it exists to
        /// account for the boxes layout produced.
        fn vtPath(_: *anyopaque, _: f32, _: f32, _: Path, _: Fill, _: Rect) void {}

        fn vtQuad(ptr: *anyopaque, rect: Rect, fill: Fill, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (rect.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .quad = .{ .rect = rect, .fill = fill, .clip = clip } }) catch {
                self.failed = true;
            };
        }

        fn vtRrect(ptr: *anyopaque, rect: Rect, radius: f32, fill: Fill, stroke: ?u8, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (rect.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .rrect = .{
                .rect = rect,
                .radius = radius,
                .fill = fill,
                .stroke = stroke,
                .clip = clip,
            } }) catch {
                self.failed = true;
            };
        }

        fn vtHalo(ptr: *anyopaque, rect: Rect, corner: f32, h: Halo, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // The halo reaches past the element, so it is pruned against the
            // grown box -- pruning on `rect` would drop a shadow that is
            // entirely outside the shape it belongs to.
            const grow = h.spread + h.blur + 1;
            const box = Rect{
                .x = rect.x + h.offset[0] - grow,
                .y = rect.y + h.offset[1] - grow,
                .w = rect.w + grow * 2,
                .h = rect.h + grow * 2,
            };
            if (box.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .halo = .{ .rect = rect, .corner = corner, .halo = h, .clip = clip } }) catch {
                self.failed = true;
            };
        }
        /// Sticky for the primitives after it.
        fn vtSetFace(ptr: *anyopaque, face: u16) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.cur_face = face;
        }

        fn vtSetWeight(ptr: *anyopaque, weight: u16) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.cur_weight = weight;
        }

        fn vtText(ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Text has no rect of its own, so the prune needs the metrics that
            // will draw it. Measured twice per line overall (layout, then here)
            // and never per pixel.
            const tm = self.metrics.measureText(bytes, size);
            // Grown by the glow, when there is one: a halo reaches past the
            // glyph box, and pruning on the bare box would discard one that sits
            // entirely outside the letters it belongs to.
            const grow = if (self.pending_halo) |h| h.blur + h.spread else 0;
            const box: Rect = .{ .x = x - grow, .y = y - grow, .w = tm.width + grow * 2, .h = tm.height + grow * 2 };
            if (box.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .text = .{
                .x = x,
                .y = y,
                .size = size,
                .fill = fill,
                .bytes = bytes,
                .clip = clip,
                .face = self.cur_face,
                .weight = self.cur_weight,
                .text_halo = self.pending_halo,
            } }) catch {
                self.failed = true;
            };
            self.pending_halo = null;
        }

        fn vtTextHalo(ptr: *anyopaque, x: f32, y: f32, size: f32, h: Halo, bytes: []const u8, clip: Rect) void {
            _ = x;
            _ = y;
            _ = size;
            _ = bytes;
            _ = clip;
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.pending_halo = h;
        }

        fn vtStrokedText(ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, width: u8, clip: Rect, kind: u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Queue it exactly as `vtText` does, carrying the width; the
            // canvas picks the stroked path off `.stroke` when it paints.
            // This used to discard every parameter, so a stroked label was
            // collected as NOTHING -- no prim, no draw, and the prim count
            // did not move because nothing was ever appended.
            const tm = self.metrics.measureText(bytes, size);
            const box: Rect = .{ .x = x, .y = y, .w = tm.width, .h = tm.height };
            if (box.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .text = .{
                .x = x,
                .y = y,
                .size = size,
                .fill = fill,
                .bytes = bytes,
                .clip = clip,
                .face = self.cur_face,
                .weight = self.cur_weight,
                .stroke = if (kind == 0) width else null,
                .border = if (kind == 1) width else null,
                .border_fill = if (kind == 1) fill else null,
                .text_halo = self.pending_halo,
            } }) catch {
                self.failed = true;
            };
            self.pending_halo = null;
        }

        fn vtMeasure(ptr: *anyopaque, bytes: []const u8, size: f32) TextMetrics {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.measureText(bytes, size);
        }

        fn vtWrap(ptr: *anyopaque, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.wrapText(bytes, size, max_width, out);
        }

        /// Delegate, do not reimplement: the collector records primitives but has no
        /// glyphs.
        fn vtAdvanceText(ptr: *anyopaque, bytes: []const u8, size: f32, index: usize) f32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.advanceText(bytes, size, index);
        }

        fn vtHitText(ptr: *anyopaque, bytes: []const u8, size: f32, x: f32) usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.hitText(bytes, size, x);
        }
    };
}

/// What a trimmed label ends with.
const ellipsis: []const u8 = "\xe2\x80\xa6";

const Fitted = struct {
    bytes: []const u8,
    width: f32,
    ellipsis: bool,
};

/// The longest whole-codepoint prefix of `bytes` that fits `max_w`, keeping room for the
/// ellipsis whenever anything has to be dropped.
fn fitText(r: Renderer, bytes: []const u8, size: f32, max_w: f32) Fitted {
    const full = r.measureText(bytes, size);
    if (full.width <= max_w) return .{ .bytes = bytes, .width = full.width, .ellipsis = false };
    const ell_w = r.measureText(ellipsis, size).width;
    if (ell_w > max_w) return .{ .bytes = bytes[0..0], .width = 0, .ellipsis = false };
    var end = bytes.len;
    while (end > 0) {
        end = prevCodepointStart(bytes, end);
        while (end > 0 and bytes[end - 1] == ' ') end -= 1;
        const w = r.measureText(bytes[0..end], size).width;
        if (w + ell_w <= max_w) return .{ .bytes = bytes[0..end], .width = w, .ellipsis = true };
    }
    return .{ .bytes = bytes[0..0], .width = 0, .ellipsis = true };
}

/// Start of the codepoint ending at `end`. Continuation bytes are 0b10xxxxxx, so walking
/// back over them lands on a lead byte.
fn prevCodepointStart(bytes: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var i = end - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Rough metrics for tools and tests: 0.58em per glyph, no glyph data needed.
pub fn nominalTextMetrics(bytes: []const u8, size: f32) TextMetrics {
    const h = size;
    return .{
        .width = @as(f32, @floatFromInt(bytes.len)) * size * 0.58,
        .height = h,
        .ascent = h * 0.8,
        .descent = -h * 0.2,
        .line_height = h,
    };
}

/// A metrics-only renderer that draws nothing.
pub fn nominalRenderer() Renderer {
    return .{ .ptr = undefined, .vtable = &.{
        .quad = nominalQuad,
        .path = nominalPath,
        .rrect = nominalRrect,
        .text = nominalText,
        .stroked_text = nominalStrokedText,
        .text_halo = nominalTextHalo,
        .set_face = nominalSetFace,
        .set_weight = nominalSetWeight,
        .halo = nominalHalo,
        .frost = nominalFrost,
        .measure_text = nominalMeasure,
        .measure_text_face = nominalMeasureFace,
        .wrap_text = nominalWrap,
        .advance_text = nominalAdvance,
        .hit_text = nominalHit,
        .blit = nominalBlit,
        .blit_svg = nominalBlitSvg,
        .blit_image = nominalBlitImage,
        .measure_image = nominalMeasureImage,
    } };
}

/// Metrics-only: an icon contributes no metrics, so it rasterises nothing.
fn nominalBlitSvg(_: *anyopaque, _: Rect, _: []const u8, _: [3]u8, _: Rect) void {}

/// Metrics-only: an image draws nothing.
fn nominalBlitImage(_: *anyopaque, _: Rect, _: []const u8, _: ImageFit, _: Rect) void {}

/// Metrics-only: no filesystem, so no image is measurable. Square is the
/// documented fallback, and `measure` already applies it to a null.
fn nominalMeasureImage(_: *anyopaque, _: []const u8) ?[2]u32 {
    return null;
}

/// Metrics-only: an icon contributes no metrics, so it draws nothing.
fn nominalBlit(_: *anyopaque, _: Rect, _: []const u8, _: u32, _: u32, _: Rect) void {}

/// Metrics-only: a frost has no shape and no metrics, so it draws nothing.
fn nominalFrost(_: *anyopaque, _: Rect, _: f32, _: f32, _: Rect) void {}

/// Metrics-only advance: 0.58em per byte, matching `nominalTextMetrics`.
fn nominalAdvance(_: *anyopaque, bytes: []const u8, size: f32, index: usize) f32 {
    return @as(f32, @floatFromInt(@min(index, bytes.len))) * size * 0.58;
}

/// Metrics-only hit test: the nearest whole byte at 0.58em each.
fn nominalHit(_: *anyopaque, bytes: []const u8, size: f32, x: f32) usize {
    const per = size * 0.58;
    if (per <= 0 or x <= 0) return 0;
    const n: usize = @intFromFloat(@max(0, @round(x / per)));
    return @min(n, bytes.len);
}

/// Byte-ish wrap for the metrics-only renderer: same greedy rule, 0.58em/char.
fn nominalWrap(_: *anyopaque, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
    if (out.len == 0) return 0;
    const per = size * 0.58;
    const cap: usize = if (per <= 0) bytes.len else @intFromFloat(@max(1, @floor(max_width / per)));
    var n: usize = 0;
    var start: usize = 0;
    while (true) {
        if (n >= out.len) return n;
        const nl = std.mem.indexOfScalarPos(u8, bytes, start, '\n');
        const hard_end = nl orelse bytes.len;
        var end = @min(hard_end, start + cap);
        if (end < hard_end) {
            if (std.mem.lastIndexOfScalar(u8, bytes[start..end], ' ')) |sp| end = start + sp;
        }
        if (end == start) end = @min(start + 1, hard_end);
        out[n] = bytes[start..end];
        n += 1;
        if (hard_end >= bytes.len and end >= hard_end) return n;
        start = if (nl != null and end == hard_end) hard_end + 1 else @min(end + 1, bytes.len);
        if (start > bytes.len) return n;
    }
}

fn nominalMeasure(_: *anyopaque, bytes: []const u8, size: f32) TextMetrics {
    return nominalTextMetrics(bytes, size);
}

fn nominalMeasureFace(_: *anyopaque, bytes: []const u8, size: f32, _: u16) TextMetrics {
    return nominalTextMetrics(bytes, size);
}

fn nominalPath(_: *anyopaque, _: f32, _: f32, _: Path, _: Fill, _: Rect) void {}

fn nominalQuad(_: *anyopaque, _: Rect, _: Fill, _: Rect) void {}
fn nominalRrect(_: *anyopaque, _: Rect, _: f32, _: Fill, _: ?u8, _: Rect) void {}
fn nominalText(_: *anyopaque, _: f32, _: f32, _: f32, _: Fill, _: []const u8, _: Rect) void {}
fn nominalStrokedText(_: *anyopaque, _: f32, _: f32, _: f32, _: Fill, _: []const u8, _: u8, _: Rect, _: u8) void {}
fn nominalTextHalo(_: *anyopaque, _: f32, _: f32, _: f32, _: Halo, _: []const u8, _: Rect) void {}
fn nominalSetFace(_: *anyopaque, _: u16) void {}
fn nominalSetWeight(_: *anyopaque, _: u16) void {}
fn nominalHalo(_: *anyopaque, _: Rect, _: f32, _: Halo, _: Rect) void {}
// ---------------------------------------------------------------------------
// messages / runtime
// ---------------------------------------------------------------------------

/// What `update` asks the runtime to do after a message. A change the app asks the runtime
/// to make to focus.
pub const FocusChange = union(enum) {
    set: u64,
    clear,
};

pub fn Action(comptime M: type) type {
    return struct {
        repaint: bool = true,
        quit: bool = false,
        /// work to run off the UI thread; its result comes back as a message
        cmd: ?Cmd(M) = null,
        /// Whether the frame clock keeps ticking.
        animate: ?bool = null,
        /// Move focus, or give it up.
        focus: ?FocusChange = null,
        /// Move a viewport's offset.
        scroll: ?ScrollChange = null,
        /// Put these bytes on the clipboard.
        clipboard: ?[]const u8 = null,

        pub fn then(c: Cmd(M)) @This() {
            return .{ .cmd = c };
        }
    };
}

/// A job that runs on a worker thread and produces at most one message. `ctx` must outlive
/// the job (the runtime joins its workers on deinit).
pub fn Cmd(comptime M: type) type {
    return struct {
        ctx: *const anyopaque,
        run: *const fn (ctx: *const anyopaque) ?M,
    };
}

/// Zig 0.16 moved the blocking mutex to `std.Io.Mutex`, which needs an `Io` to lock.
const Spin = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Spin) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Spin) void {
        self.flag.store(false, .release);
    }
};

/// Runs `Cmd`s on worker threads and hands their messages back to the runtime.
pub fn Executor(comptime M: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        mutex: Spin = .{},
        done: std.ArrayList(M) = .empty,
        /// One entry per command whose worker may still be running.
        handles: std.ArrayList(Handle) = .empty,
        outstanding: usize = 0, // guarded by mutex
        lost: usize = 0, // guarded by mutex
        /// How many commands may hold a thread at once. A screen that fires a command per
        /// row would otherwise be a thread per row.
        max_running: usize = 8,
        running: usize = 0, // guarded by mutex
        /// Commands over the cap, waiting for a worker to take one.
        pending: std.ArrayList(Cmd(M)) = .empty, // guarded by mutex

        /// Per-command completion, heap-owned so its address is stable: the handle list can
        /// reallocate while a worker is still writing to this.
        const Job = struct {
            finished: std.atomic.Value(bool) = .init(false),
        };
        const Handle = struct {
            thread: std.Thread,
            job: *Job,
        };

        pub fn submit(self: *Self, cmd: Cmd(M)) void {
            self.mutex.lock();
            self.outstanding += 1;
            if (self.running >= self.max_running) {
                // Every slot is taken. Waiting here is not an option, so the
                // command is queued and a worker takes it when it finishes --
                // which needs no waiting primitive at all.
                self.pending.append(self.gpa, cmd) catch {
                    self.outstanding -= 1;
                    self.lost += 1;
                };
                self.mutex.unlock();
                return;
            }
            self.running += 1;
            self.mutex.unlock();

            const job = self.gpa.create(Job) catch {
                // Without a completion flag the handle could never be reaped,
                // which is the unbounded list this type exists to avoid. Not
                // starting is the honest outcome, and it is counted.
                self.failStart();
                return;
            };
            job.* = .{};

            const t = std.Thread.spawn(.{}, worker, .{ self, cmd, job }) catch {
                self.gpa.destroy(job);
                self.failStart();
                return;
            };
            self.handles.append(self.gpa, .{ .thread = t, .job = job }) catch {
                // The handle is gone, so nothing can join this worker, and
                // dropping a joinable thread is how a shutdown race gets
                // written. Detaching is safe here: its only contact with
                // `self` is inside the mutex, and `deinit` waits for
                // `outstanding` to reach zero before freeing anything. The
                // `Job` is deliberately leaked rather than freed -- the worker
                // still writes to it, and there is no one left to free it
                // afterwards. One allocation on an allocation-failure path.
                t.detach();
            };
        }

        /// Give back a slot that never became a thread. It is not in flight, so it must not
        /// keep `busy()` true, and the app will never hear from it.
        fn failStart(self: *Self) void {
            self.mutex.lock();
            self.running -= 1;
            self.outstanding -= 1;
            self.lost += 1;
            self.mutex.unlock();
        }

        /// Queue a completed message. The CALLER holds the mutex.
        fn queueLocked(self: *Self, m: M) void {
            self.done.append(self.gpa, m) catch {
                self.lost += 1;
            };
        }

        fn worker(self: *Self, first: Cmd(M), job: *Job) void {
            var cmd = first;
            while (true) {
                const out = cmd.run(cmd.ctx);
                self.mutex.lock();
                if (out) |m| self.queueLocked(m);
                // THIS command is finished, whichever thread ran it. Counting
                // the decrement once at exit instead would leave every adopted
                // command on `outstanding` forever -- `busy()` true for the
                // session and `deinit` spinning, which is how this bug first
                // showed up: as a hang, not a failure.
                self.outstanding -= 1;
                if (self.pending.items.len != 0) {
                    // Take over a command that could not have a thread of its
                    // own. The slot is unchanged, so `running` does not move.
                    cmd = self.pending.orderedRemove(0);
                    self.mutex.unlock();
                    continue;
                }
                self.running -= 1;
                self.mutex.unlock();
                // LAST statement: once this store is visible, `reap` may join
                // this thread at any moment, so nothing may touch `self` or
                // `job` after it, and the unlock has to have happened first.
                job.finished.store(true, .release);
                return;
            }
        }

        /// Commands that could not be started.
        pub fn lostCommands(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.lost;
        }

        /// Join workers that have finished, so `handles` stays bounded by the commands IN
        /// FLIGHT rather than growing for the life of the app.
        pub fn reap(self: *Self) void {
            var i: usize = 0;
            while (i < self.handles.items.len) {
                const h = self.handles.items[i];
                if (!h.job.finished.load(.acquire)) {
                    i += 1;
                    continue;
                }
                h.thread.join();
                self.gpa.destroy(h.job);
                _ = self.handles.swapRemove(i);
            }
        }

        /// True while workers are still running (cheap hint for the loop: it should poll
        /// with a short timeout instead of blocking forever).
        pub fn busy(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.outstanding > 0;
        }

        /// Move finished messages into `list`. Called from the UI thread.
        pub fn drainInto(self: *Self, list: *std.ArrayList(M)) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.done.items.len == 0) return;
            try list.appendSlice(self.gpa, self.done.items);
            self.done.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            // `handles` need not hold every handle (an append that failed
            // detached its worker), so wait for the work itself to finish
            // before freeing what the workers reach.
            //
            // The wait is a yield loop, not a sleep, because 0.16 has no
            // io-free sleep left: `std.time.sleep` is gone, `std.posix` has no
            // nanosleep, and every remaining form (`std.Io.sleep`,
            // `Clock.sleep`, `Timeout.sleep`) takes an `io`. This type
            // deliberately has none -- the runtime it belongs to is io-free so
            // it stays headlessly testable -- and normally the loop does not
            // iterate at all, since `reap` has already joined everything.
            while (true) {
                self.mutex.lock();
                const n = self.outstanding;
                self.mutex.unlock();
                if (n == 0) break;
                std.Thread.yield() catch {};
            }
            for (self.handles.items) |h| {
                h.thread.join();
                self.gpa.destroy(h.job);
            }
            self.handles.deinit(self.gpa);
            self.done.deinit(self.gpa);
            // Emptied by the workers above: one only exits when it finds this
            // queue empty, so reaching zero `outstanding` means it is empty.
            self.pending.deinit(self.gpa);
        }
    };
}

pub const keys = @import("keys.zig");

/// Re-exported so no call site changes: `elmz.Key` is the name everything already uses, and
/// the definitions simply live in `keys.zig` now.
pub const Mods = keys.Mods;
pub const Named = keys.Named;
pub const Key = keys.Key;
pub const ShortcutKey = keys.ShortcutKey;
pub const Shortcut = keys.Shortcut;
pub const shortcutMatches = keys.shortcutMatches;
pub const isBareShortcut = keys.isBareShortcut;
pub const shortcutFor = keys.shortcutFor;
pub const checkShortcuts = keys.checkShortcuts;

/// Scroll wheel movement, in the platform's own units. The deltas are NOT normalised.
pub const Wheel = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

pub const Event = union(enum) {
    /// window wants to close; the runner stops.
    quit,
    /// The window's size changed, so the next frame must be built for a different box.
    resize,
    pointer_down: [2]f32,
    pointer_up: [2]f32,
    pointer_move: [2]f32,
    /// The gesture ended without a release we will ever see: focus taken away, or the
    /// pointer left the window mid-drag.
    pointer_cancel,
    key: Key,
    /// The release matching one `key`. Never repeats.
    key_up: Key,
    /// Text the user actually typed, as UTF-8 bytes.
    text: []const u8,
    /// Wheel movement.
    wheel: Wheel,
};

/// Which half of a keystroke an `on_key` hook is being told about. `repeat` lives on `Key`,
/// not here: a repeat is still a press.
pub const Phase = enum { down, up };

/// What the platform has told us about the pointer.
pub const Pointer = struct {
    /// last known position, if the backend has ever reported one
    pos: ?[2]f32 = null,
};

/// What paint needs: the position, and the rect that owns the press in flight. Derived in
/// `Runtime.frame()` from `Runtime.press`, never stored beside it.
pub const PointerView = struct {
    pos: ?[2]f32 = null,
    /// geometry of the region that owns the press, compared by identity
    held: ?Region = null,
};

/// What a paint pass knows about hover.
const Hover = struct {
    out: ?*std.ArrayList(Region) = null,
    target: ?Region = null,
    /// Which key the runtime considers focused.
    focus: ?u64 = null,
    /// The frame clock, for anything that blinks.
    elapsed: f32 = 0,
    since_input: f32 = 0,
};

/// The platform layer, expressed in elmz terms only.
pub const Window = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Next event, blocking up to `timeout_ms` (-1 = forever). null = timeout.
        poll: *const fn (ptr: *anyopaque, timeout_ms: i32) ?Event,
        /// Hand a finished RGBA frame to the screen.
        present: *const fn (ptr: *anyopaque, pixels: []const u8, pixel_size: Size) void,
        /// Logical window size, in the same units events are reported in.
        size: *const fn (ptr: *anyopaque) Size,
        /// Device pixels per logical unit; 1.0 is unscaled.
        density: *const fn (ptr: *anyopaque) f32,
        deinit: *const fn (ptr: *anyopaque) void,
        /// Clipboard text, for PASTE. Borrowed, valid until the next call, so a caller that
        /// keeps it must copy it -- the same contract as `Event.text`.
        clipboard_text: ?*const fn (ptr: *anyopaque) ?[]const u8 = null,
        /// Put text on the clipboard: the outbound half of the same seam. Optional for the
        /// same reason.
        set_clipboard: ?*const fn (ptr: *anyopaque, text: []const u8) void = null,
    };

    pub fn poll(self: Window, timeout_ms: i32) ?Event {
        return self.vtable.poll(self.ptr, timeout_ms);
    }

    pub fn present(self: Window, pixels: []const u8, pixel_size: Size) void {
        self.vtable.present(self.ptr, pixels, pixel_size);
    }

    pub fn size(self: Window) Size {
        return self.vtable.size(self.ptr);
    }

    pub fn density(self: Window) f32 {
        return self.vtable.density(self.ptr);
    }

    pub fn deinit(self: Window) void {
        self.vtable.deinit(self.ptr);
    }

    /// What is on the clipboard, or null when there is nothing to read.
    pub fn clipboardText(self: Window) ?[]const u8 {
        const f = self.vtable.clipboard_text orelse return null;
        return f(self.ptr);
    }

    pub fn setClipboard(self: Window, text: []const u8) void {
        const f = self.vtable.set_clipboard orelse return;
        f(self.ptr, text);
    }
};

pub fn Runtime(comptime S: type, comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Elem = Element(M);
        pub const FrameT = Frame(M);
        pub const UiT = Ui(M);

        gpa: Allocator,
        state: S,
        /// Name -> face index, supplied by whoever owns the font registry.
        face_lookup: ?*const FaceLookup = null,
        updateFn: *const fn (*S, M) Action(M),
        viewFn: *const fn (*S, *UiT) *Elem,
        ui: UiT,
        exec: ?Executor(M) = null,
        /// last position the platform reported
        pointer: Pointer = .{},
        /// The press in flight, if any.
        press: Press(M) = .{},
        /// Which keyed element currently holds focus, or null for none.
        focus: ?u64 = null,
        /// Seconds since the runtime started, accumulated from the RAW clock delta rather
        /// than the clamped `dt` given to `on_tick`: the clamp exists so a stall.
        elapsed: f32 = 0,
        /// Seconds since the last key or text event. The runner resets it and mirrors it
        /// into `Ui`; nothing else writes it.
        since_input: f32 = 0,
        /// How long the pointer has rested on the current region, reset when it moves to a
        /// different one.
        hover_since: f32 = 0,
        /// Whether a text-input widget holds focus, which is what suppresses bare-key
        /// shortcuts -- an unmodified `s` must type an `s`, not fire a command.
        text_editing: bool = false,
        /// The window, when there is one.
        window: ?Window = null,
        /// Optional keystroke hooks, wired by `runApp` from the app declaration.
        on_key: ?*const fn (*S, Key, Phase) ?M = null,
        /// Same contract for typed text; see `Event.text` for why it is not derivable from
        /// keys and why the slice is borrowed.
        on_text: ?*const fn (*S, []const u8) ?M = null,
        /// Scroll wheel, delivered raw and unclassified.
        on_wheel: ?*const fn (*S, Wheel) ?M = null,
        /// A press that landed on NO region at all: no control, no thumb, no viewport.
        on_outside: ?*const fn (*S, [2]f32) ?M = null,
        /// Frame clock: seconds since the previous tick, called at the top of every loop
        /// iteration while the app is animating.
        on_tick: ?*const fn (*S, f32) ?M = null,
        /// True while the app wants frames without input. Lives here because the loop
        /// consults it BEFORE it decides how long to block in poll.
        animate: bool = false,
        /// Offsets for keyed scroll viewports.
        scroll_slots: [64]ScrollSlot = @splat(.{}),
        scroll_n: usize = 0,

        pub fn init(
            gpa: Allocator,
            initial: S,
            updateFn: *const fn (*S, M) Action(M),
            viewFn: *const fn (*S, *UiT) *Elem,
        ) Self {
            return .{
                .gpa = gpa,
                .state = initial,
                .updateFn = updateFn,
                .viewFn = viewFn,
                .ui = UiT.init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.exec) |*e| e.deinit();
            self.ui.deinit();
        }

        pub fn dispatch(self: *Self, msg: M) Action(M) {
            const action = self.updateFn(&self.state, msg);
            if (action.focus) |change| self.focus = switch (change) {
                .set => |key| key,
                .clear => null,
            };
            if (action.animate) |v| self.animate = v;
            if (action.scroll) |change| switch (change) {
                .to => |t| self.scrollTo(t.key, t.offset),
                .by => |b| self.scrollBy(b.key, b.dy),
            };
            // Outbound clipboard. The app decides WHAT and WHEN -- it owns the
            // selection -- and the runtime only knows how to reach the
            // platform. An effect rather than a message for the same reason
            // `focus` is: there is no one to send it to.
            if (action.clipboard) |text| {
                if (self.window) |w| w.setClipboard(text);
            }
            if (action.cmd) |cmd| {
                if (self.exec == null) self.exec = Executor(M){ .gpa = self.gpa };
                self.exec.?.submit(cmd);
            }
            return action;
        }

        /// Messages produced by commands since the last call. Dispatch them from the UI
        /// thread; they are ordinary messages.
        pub fn takeAsync(self: *Self, list: *std.ArrayList(M)) !void {
            if (self.exec) |*e| {
                try e.drainInto(list);
                // Reap on the drain path, which the loop already walks every
                // iteration: one lock and a compare while commands are in
                // flight, and it stops finished workers piling up.
                e.reap();
            }
        }

        /// True while a command is still running.
        pub fn asyncBusy(self: *Self) bool {
            if (self.exec) |*e| return e.busy();
            return false;
        }

        /// view -> measure -> paint. Returns primitives plus hit regions.
        fn scrollAtKey(self: *const Self, key: ?u64) f32 {
            const k = key orelse return 0;
            for (self.scroll_slots[0..self.scroll_n]) |s| {
                if (s.key == k) return s.offset;
            }
            return 0;
        }

        pub fn scrollOffset(self: *const Self, key: u64) f32 {
            return self.scrollAtKey(key);
        }

        fn scrollAtKeyX(self: *const Self, key: ?u64) f32 {
            const k = key orelse return 0;
            for (self.scroll_slots[0..self.scroll_n]) |s| {
                if (s.key == k) return s.offset_x;
            }
            return 0;
        }

        pub fn scrollOffsetX(self: *const Self, key: u64) f32 {
            return self.scrollAtKeyX(key);
        }

        /// The horizontal twin of `scrollTo`: same slot, other half.
        pub fn scrollToX(self: *Self, key: u64, off: f32) void {
            for (self.scroll_slots[0..self.scroll_n]) |*s| {
                if (s.key == key) {
                    s.offset_x = off;
                    return;
                }
            }
            self.scrollTo(key, 0);
            self.scroll_slots[self.scroll_n - 1].offset_x = off;
        }

        /// Set a viewport's offset outright.
        pub fn scrollTo(self: *Self, key: u64, off: f32) void {
            for (self.scroll_slots[0..self.scroll_n]) |*s| {
                if (s.key == key) {
                    s.offset = off;
                    return;
                }
            }
            if (self.scroll_n == self.scroll_slots.len) {
                std.mem.copyForwards(
                    ScrollSlot,
                    self.scroll_slots[0 .. self.scroll_slots.len - 1],
                    self.scroll_slots[1..],
                );
                self.scroll_n -= 1;
            }
            self.scroll_slots[self.scroll_n] = .{ .key = key, .offset = off };
            self.scroll_n += 1;
        }

        /// Move a viewport.
        pub fn scrollBy(self: *Self, key: u64, dy: f32) void {
            for (self.scroll_slots[0..self.scroll_n]) |*s| {
                if (s.key == key) {
                    s.offset += dy;
                    return;
                }
            }
            if (self.scroll_n == self.scroll_slots.len) {
                std.mem.copyForwards(
                    ScrollSlot,
                    self.scroll_slots[0 .. self.scroll_slots.len - 1],
                    self.scroll_slots[1..],
                );
                self.scroll_n -= 1;
            }
            self.scroll_slots[self.scroll_n] = .{ .key = key, .offset = dy };
            self.scroll_n += 1;
        }

        /// Push the store into the tree.
        fn injectScrollOffsets(self: *Self, e: *Elem, path: u64) void {
            // EVERY container is a candidate viewport now: whether it overflows
            // is decided by the box its parent paints it into, which is only
            // known during paint. Stamping the identity and the offset here is
            // free for one that turns out not to overflow -- the number is never
            // read.
            //
            // Identity comes from the TREE PATH, so an app declares nothing. The
            // path is unique per node by construction, which is also why a
            // synthesized key cannot collide in the frame-global duplicate-key
            // guard the way an app-authored one could.
            e.node_path = path;
            const tag = std.meta.activeTag(e.geometry);
            switch (tag) {
                .column, .row, .stack, .scroll => {
                    e.scroll_key = path;
                    e.scroll_offset = self.scrollAtKey(path);
                    e.scroll_offset_x = self.scrollAtKeyX(path);
                },
                .text, .button, .bar, .rect, .icon, .image => {
                    // A widget normally owns no scroll state, but one whose
                    // payload says so takes the SAME per-path slot the
                    // containers use. `scrollChrome` keys the thumbs off
                    // `scroll_key`, so without this a scrolling field records
                    // no viewport and paints no bar.
                    if (e.widget) |wp| {
                        const scrolls = switch (wp.*) {
                            .input => |ti| ti.scrolls,
                            .slider, .select, .menu, .toast => false,
                        };
                        if (scrolls) {
                            e.scroll_key = path;
                            e.scroll_offset = self.scrollAtKey(path);
                            e.scroll_offset_x = self.scrollAtKeyX(path);
                        }
                    }
                },
            }
            switch (e.geometry) {
                .column => |c| for (c.children, 0..) |ch, i| self.injectScrollOffsets(ch, pathChild(path, i)),
                .row => |c| for (c.children, 0..) |ch, i| self.injectScrollOffsets(ch, pathChild(path, i)),
                .scroll => |c| self.injectScrollOffsets(c.child, pathChild(path, 0)),
                // A stack is a container like any other: without this arm the
                // else-branch drops the whole subtree, and a viewport nested in
                // an overlay never receives its offset -- it renders as if it
                // could not scroll, with a thumb that is there and inert.
                .stack => |c| for (c.children, 0..) |ch, i| self.injectScrollOffsets(ch, pathChild(path, i)),
                .text, .button, .bar, .rect, .icon, .image => {},
            }
        }

        /// `metrics` is the renderer that will draw this frame, normally
        /// `canvas.renderer()`.
        pub fn frame(self: *Self, size: Size, metrics: Renderer) !FrameT {
            self.ui.reset();
            // `failed` describes THIS build, so it cannot outlive a reset: an
            // allocation that failed once would otherwise brand every later
            // frame as broken, including frames that built cleanly.
            self.ui.failed = false;
            self.ui.fail_kind = .layout_allocation;
            self.ui.fail_len = 0;

            // ...but a failure raised from outside a build is not per-build
            // state, and survives the reset above by being kept elsewhere.
            if (self.ui.ext_len > 0) {
                self.ui.failed = true;
                self.ui.fail_kind = self.ui.ext_kind;
                const n = @min(self.ui.ext_len, self.ui.fail_buf.len);
                @memcpy(self.ui.fail_buf[0..n], self.ui.ext_buf[0..n]);
                self.ui.fail_len = n;
            }

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            const a = arena.allocator();

            // The read side of `Action.focus`. Mirrored every frame, so view
            // never has to remember what it asked for.
            self.ui.focus = self.focus;
            self.ui.elapsed = self.elapsed;
            self.ui.since_input = self.since_input;
            self.ui.hover_since = self.hover_since;
            self.ui.scrolls = self.scroll_slots[0..self.scroll_n];
            // Mirrored every frame beside the scroll offsets, for the same
            // reason: `view` must not have to remember how it was configured,
            // and a runtime torn down and rebuilt cannot leave a stale handle.
            self.ui.face_lookup = self.face_lookup;

            const root = self.viewFn(&self.state, &self.ui);
            // The root's path is a constant, so the window itself is the first
            // viewport: content taller than the window scrolls it, which is the
            // case an app hits without doing anything at all.
            self.injectScrollOffsets(root, scroll_path_root);

            var collector: Collector(M) = .{ .gpa = a, .metrics = metrics };
            const r = collector.renderer();

            var hits: std.ArrayList(Hit(M)) = .empty;
            const view: PointerView = .{
                .pos = self.pointer.pos,
                .held = if (self.press.captured) |h| .{ .rect = h.rect, .clip = h.clip, .key = h.key } else null,
            };
            const root_rect: Rect = .{ .x = 0, .y = 0, .w = size.w, .h = size.h };

            // Hover belongs to the innermost element under the pointer, and a
            // parent cannot know that while it lays down its own background:
            // children are painted after it. So an idle pointer costs a scan
            // traversal first (no rasterising, prims discarded) to resolve
            // which region actually owns the hover, then one real pass that
            // paints with that answer. A press in flight shows no hover at
            // all, so those frames keep the single pass.
            var resolved: ?Region = null;
            // Resolved independently of the hover target, and by its own walk:
            // the innermost region WITH a tip wins, which is what lets a child
            // with none fall through to an ancestor that has one.
            var tip: ?Region = null;
            if (view.pos) |p| {
                if (view.held == null) {
                    var scan_hits: std.ArrayList(Hit(M)) = .empty;
                    defer scan_hits.deinit(a);
                    var regions: std.ArrayList(Region) = .empty;
                    var scan: Collector(M) = .{ .gpa = a, .metrics = metrics };
                    try root.paint(scan.renderer(), root_rect, Rect.unbounded, view, &scan_hits, a, .{ .out = &regions }, self.ui.theme);
                    // Innermost last: children are painted after their parent,
                    // so the last region holding the point is the one to light.
                    var i = regions.items.len;
                    while (i > 0) {
                        i -= 1;
                        if (regions.items[i].holds(p)) {
                            resolved = regions.items[i];
                            break;
                        }
                    }
                    var ti = regions.items.len;
                    while (ti > 0) {
                        ti -= 1;
                        const reg = regions.items[ti];
                        if (reg.tooltip != null and reg.holds(p)) {
                            tip = reg;
                            break;
                        }
                    }
                }
            }

            try root.paint(r, root_rect, Rect.unbounded, view, &hits, a, .{ .target = resolved, .focus = self.focus, .elapsed = self.elapsed, .since_input = self.since_input }, self.ui.theme);

            // Keys are identity, and identity that collides is worse than no
            // identity: `rebind` would bind a press to whichever twin it met
            // first. So it is a bug -- but not one worth taking the app down
            // for. It is reported the same way a failed allocation is, through
            // the band, which keeps the frame usable and names the fault.

            // Does the keyboard belong to a text field this frame? Derived
            // from the frame that just painted, so a bare-key shortcut cannot
            // fire on the same frame focus moved into a field. Read through the
            // widget payload, not from the kind: only the payload knows, and
            // `hit()` strips it from the copy it hands out.
            self.text_editing = blk: {
                const fk = self.focus orelse break :blk false;
                for (hits.items) |h| {
                    const k = h.key orelse continue;
                    if (k != fk) continue;
                    const wp = h.widget orelse continue;
                    if (wp.* == .input) break :blk true;
                }
                break :blk false;
            };

            // ---- popup layer ----
            // Painted last and hit-tested first, and both fall out of the
            // order these lists are appended in: the prim list paints front to
            // back, and `hit` walks the region list from the END. So a popup
            // needs no layer machinery of its own -- only to be appended after
            // the tree, once layout has given its anchor a rectangle to sit
            // against. That rectangle is the whole reason this cannot live in
            // `view`, which runs before layout.
            {
                // The tree's own regions are a stable prefix: appends below
                // only ever land after `tree_len`, so indexing from here is
                // immune to the list reallocating mid-loop. A fixed slot array
                // would have silently dropped the ninth open popup, which is
                // the "never red" failure -- something ignored with no report.
                const tree_len = hits.items.len;
                var idx: usize = 0;
                while (idx < tree_len) : (idx += 1) {
                    const wp = hits.items[idx].widget orelse continue;
                    const is_open = switch (wp.*) {
                        .select => |sel| sel.open,
                        .menu => |mn| mn.open,
                        else => false,
                    };
                    if (!is_open) continue;
                    const anchor_hit = hits.items[idx];
                    const items: []const Choice(M) = switch (wp.*) {
                        .select => |sel| sel.options,
                        .menu => |mn| mn.items,
                        else => continue,
                    };
                    const active_idx: ?usize = switch (wp.*) {
                        .select => |sel| if (sel.active.*) |v| @as(usize, v) else null,
                        .menu => |mn| if (mn.active.*) |v| @as(usize, v) else null,
                        else => null,
                    };
                    const toggle: M = switch (wp.*) {
                        .select => |sel| sel.msg,
                        .menu => |mn| mn.toggle,
                        else => continue,
                    };
                    const mode: PopupAnchor = switch (wp.*) {
                        .menu => .below,
                        else => .centred,
                    };

                    var widest: f32 = anchor_hit.rect.w;
                    for (items) |it| {
                        if (it.label.len == 0) continue;
                        const mw = metrics.measureText(it.label, 14).width + 24;
                        if (mw > widest) widest = mw;
                    }

                    const lay = popupLayout(anchor_hit.rect, widest, items.len, active_idx, size, mode, popup_row_h);
                    if (lay.count == 0) continue;

                    // The scrim is appended BEFORE the rows, so the rows are
                    // tested first: a click on an option must not also be a
                    // click outside it. It carries the toggle, which is what
                    // makes a click anywhere else dismiss. `on_outside` cannot
                    // do this -- a click on another control claims that
                    // control, so nothing would ever reach the app.
                    try hits.append(a, .{ .rect = root_rect, .clip = root_rect, .msg = toggle });

                    r.quad(lay.rect, .{ .solid = self.ui.theme.panel }, root_rect);
                    r.quad(.{ .x = lay.rect.x, .y = lay.rect.y, .w = lay.rect.w, .h = 1 }, .{ .solid = self.ui.theme.border }, root_rect);
                    r.quad(.{ .x = lay.rect.x, .y = lay.rect.y + lay.rect.h - 1, .w = lay.rect.w, .h = 1 }, .{ .solid = self.ui.theme.border }, root_rect);

                    for (lay.first..lay.first + lay.count) |row| {
                        const ry = lay.rect.y + @as(f32, @floatFromInt(row - lay.first)) * popup_row_h;
                        const row_rect = Rect{ .x = lay.rect.x, .y = ry, .w = lay.rect.w, .h = popup_row_h };
                        const item = items[row];
                        const is_active = if (active_idx) |ai| ai == row else false;
                        if (is_active) r.quad(row_rect, .{ .solid = self.ui.theme.hover }, lay.rect);
                        if (item.label.len != 0) {
                            const fg = if (item.disabled) self.ui.theme.text_muted else self.ui.theme.text;
                            r.text(row_rect.x + 8, ry + 6, 14, .{ .solid = fg }, item.label, lay.rect);
                        }
                        if (item.msg) |m| {
                            try hits.append(a, .{
                                .rect = row_rect,
                                .clip = root_rect,
                                .msg = m,
                                .active = !item.disabled,
                            });
                        }
                    }
                }
            }

            // Checked over the hit list rather than per sibling list, so the
            // rule is the simpler one: unique within a frame.
            for (hits.items, 0..) |h, i| {
                const k = h.key orelse continue;
                for (hits.items[i + 1 ..]) |h2| {
                    if (h2.key) |k2| if (k2 == k) {
                        self.ui.failFmt(.duplicate_key, "render failed: duplicate key {d}", .{k});
                    };
                }
            }
            // A primitive the Collector could not record is a hole in the
            // frame, not a rendering choice, so it is raised the same way a
            // failed allocation is -- and, like that one, above the band block,
            // because a failure reported below the band never gets drawn.
            if (collector.failed) self.ui.failWith(.layout_allocation);

            // A failed allocation leaves the tree structurally degraded so
            // that `view` can stay infallible. Painting that degraded tree
            // silently would hide the bug behind a screen that merely looks
            // wrong, so say it out loud: a hard band across the top, drawn
            // through the same renderer as everything else, which is what puts
            // it in the prim list — and therefore inside assertions and
            // screenshots — like any other pixel.
            if (self.ui.failed) {
                r.quad(.{ .x = 0, .y = 0, .w = root_rect.w, .h = band_h }, .{ .solid = band_bg }, Rect.unbounded);
                // One line, cut at the window edge rather than wrapped: a band
                // that grew to two lines would push the whole frame down,
                // changing layout as a side effect of reporting an error.
                var msg = self.ui.failMessage();
                const room = root_rect.w - 12;
                while (msg.len > 0 and metrics.measureText(msg, 12).width > room) msg = msg[0 .. msg.len - 1];
                r.text(6, 3, 12, .{ .solid = band_fg }, msg, Rect.unbounded);
            }

            // ---- tooltip ----
            // Last of everything, because nothing is smaller than a tooltip: it
            // belongs above an open menu, a select and a toast.
            if (tip) |t| {
                // The delay is what makes a tooltip an explanation rather than a
                // flicker. Instant after that on the same frame clock -- a cold
                // half-second every time makes a toolbar feel broken, and an
                // instant show every time flickers across one.
                if (self.ui.hover_since >= 0.5) {
                    const tip_size: f32 = 13;
                    const pad_x: f32 = 6;
                    const pad_y: f32 = 4;
                    const m = metrics.measureText(t.tooltip.?, tip_size);
                    const h = tip_size + 2 * pad_y;
                    var w = m.width + 2 * pad_x;
                    if (w > root_rect.w - 4) w = root_rect.w - 4;
                    var x = t.rect.x + t.rect.w / 2 - w / 2;
                    if (x < 2) x = 2;
                    if (x + w > root_rect.w - 2) x = root_rect.w - 2 - w;
                    // Below, then above when there is no room: a tooltip that
                    // hung off the bottom edge would be unreadable, and unlike a
                    // menu it has no scroll of its own.
                    var y = t.rect.y + t.rect.h + 6;
                    if (y + h > root_rect.h - 2) y = t.rect.y - 6 - h;
                    if (y < 2) y = 2;
                    const box: Rect = .{ .x = x, .y = y, .w = w, .h = h };
                    r.quad(box, .{ .solid = self.ui.theme.panel }, Rect.unbounded);
                    r.quad(.{ .x = box.x, .y = box.y, .w = box.w, .h = 1 }, .{ .solid = self.ui.theme.border }, Rect.unbounded);
                    r.text(box.x + pad_x, box.y + pad_y, tip_size, .{ .solid = self.ui.theme.text }, t.tooltip.?, Rect.unbounded);
                }
            }

            // All allocations must happen BEFORE `arena` is copied into the
            // result: `a` points at the local `arena`, so anything allocated
            // after the copy would land in a struct nobody deinits.
            const prims = try a.dupe(Primitive, collector.prims.items);
            const hit_list = try a.dupe(Hit(M), hits.items);
            // A keyed press follows its element into the frame that was just
            // built. This runs after the hit list exists and before the caller
            // can release, so `up` tests the element's CURRENT rect.
            self.press.rebind(hit_list);

            // Text bytes still point into the UI arena, which the *next*
            // frame() resets. Copy them into this frame's arena so a frame is
            // independent of the one that follows it.
            for (prims) |*p| switch (p.*) {
                .text => |*t| t.bytes = try a.dupe(u8, t.bytes),
                else => {},
            };

            return .{
                .arena = arena,
                .prims = prims,
                .hits = hit_list,
                .size = size,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const TMsg = enum { inc, dec, reset };

const TState = struct { n: i32 = 0 };

fn tUpdate(s: *TState, m: TMsg) Action(TMsg) {
    switch (m) {
        .inc => s.n += 1,
        .dec => s.n -= 1,
        .reset => s.n = 0,
    }
    return .{};
}

fn tView(s: *TState, ui: *Ui(TMsg)) *Element(TMsg) {
    const minus = ui.button(.{ .label = "-", .msg = .dec, .width = 40 });
    const plus = ui.button(.{ .label = "+", .msg = .inc, .width = 40 });
    return ui.column(.{ .children = &.{
        ui.text(.{ .label = ui.fmt("{d}", .{s.n}), .size = 20 }),
        ui.row(.{ .children = &.{ minus, plus } }),
    } });
}

test "hit test maps a point to a message" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f.deinit();

    try std.testing.expect(f.hits.len == 2);
    // first button starts at x=0, so a click at (10, 30) hits "-"... verify via rect
    const minus = f.hits[0].rect;
    try std.testing.expectEqual(TMsg.dec, f.hitTest(.{ minus.x + 5, minus.y + 5 }).?);
    const plus = f.hits[1].rect;
    try std.testing.expectEqual(TMsg.inc, f.hitTest(.{ plus.x + 5, plus.y + 5 }).?);
    try std.testing.expect(f.hitTest(.{ 399, 199 }) == null);
}

test "update changes state, repaint refreshes view" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    _ = rt.dispatch(.inc);
    _ = rt.dispatch(.inc);
    _ = rt.dispatch(.dec);
    try std.testing.expectEqual(@as(i32, 1), rt.state.n);

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f.deinit();

    var found = false;
    for (f.prims) |p| switch (p) {
        .text => |t| if (std.mem.eql(u8, t.bytes, "1")) {
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}

test "arena is reused across frames" {
    const gpa = std.testing.allocator;
    var ui = Ui(TMsg).init(gpa);
    defer ui.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        ui.reset();
        _ = ui.text(.{ .label = "hello", .size = 12 });
        _ = ui.column(.{ .children = &.{ui.text(.{ .label = "a", .size = 12 })} });
    }
}

const RowFitMsg = enum { tap };

fn rowFitUpdate(m: *RowFitState, msg: RowFitMsg) Action(RowFitMsg) {
    _ = m;
    _ = msg;
    return .{};
}
const RowFitState = struct { wide: bool = false };

fn rowFitView(m: *RowFitState, ui: *Ui(RowFitMsg)) *Element(RowFitMsg) {
    // Wrapped text always fills what it is given, so the wide case has to use a
    // label that does not wrap or the row would squeeze in both cases and the
    // comparison would prove nothing.
    const label = if (m.wide)
        ui.text(.{ .label = "short", .size = 10 })
    else
        ui.text(.{
            .label = "a long sentence that must wrap somewhere inside this row",
            .size = 10,
            .wrap = true,
        });
    const btn = ui.button(.{ .label = "ok", .msg = .tap });
    const row = ui.row(.{ .children = &.{ label, btn } });
    const col = ui.column(.{ .children = &.{row} });
    col.width = if (m.wide) 2000 else 220;
    return col;
}

test "a squeezed row takes the deficit out of slack, not evenly" {
    // 100 + 300 asked for, 200 of that is floor, so 200 is slack -- and all of
    // it sits in the paragraph. An even split would shrink the button too and
    // hand the text room it never needed.
    const button = Extent{ .w = 100, .h = 20, .min_w = 100 };
    const para = Extent{ .w = 300, .h = 20, .min_w = 100 };
    const sum_w: f32 = 400;
    const sum_min: f32 = 200;

    try std.testing.expectApproxEqAbs(@as(f32, 300), rowChildWidth(para, sum_w, sum_min, 500), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), rowChildWidth(button, sum_w, sum_min, 250), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), rowChildWidth(para, sum_w, sum_min, 250), 0.01);

    // Below the floors everything sits at its minimum and the row overflows.
    // Clipping is the alternative, and there is no glyph clipping to clip with.
    try std.testing.expectApproxEqAbs(@as(f32, 100), rowChildWidth(para, sum_w, sum_min, 150), 0.01);
}

test "min_w is a floor: only text that wraps gives ground" {
    const gpa = std.testing.allocator;
    const r = nominalRenderer();
    var ui = Ui(RowFitMsg).init(gpa);
    defer ui.deinit();

    const plain = ui.text(.{ .label = "hello world", .size = 10 });
    const pm = plain.measure(r, 10);
    try std.testing.expectEqual(pm.w, pm.min_w);

    const wrapped = ui.text(.{ .label = "aa bbbb cc", .size = 10, .wrap = true });
    const wm = wrapped.measure(r, 200);
    try std.testing.expectApproxEqAbs(r.measureText("bbbb", 10).width, wm.min_w, 0.01);
    try std.testing.expect(wm.min_w < wm.w);

    const btn = ui.button(.{ .label = "ok", .msg = .tap });
    const bm = btn.measure(r, 10);
    try std.testing.expectEqual(bm.w, bm.min_w);

    // A width the app wrote down is both the size and the floor.
    const fixed = ui.text(.{ .label = "hello", .size = 10, .width = 90 });
    try std.testing.expectEqual(@as(f32, 90), fixed.measure(r, 500).min_w);

    // A column stacks, so its floor is the widest floor among its children.
    const col = ui.column(.{ .children = &.{ btn, wrapped } });
    const cm = col.measure(r, 1000);
    try std.testing.expectApproxEqAbs(@max(bm.min_w, wm.min_w), cm.min_w, 0.01);
}

test "a squeezed row paints the button where the row measured it" {
    const gpa = std.testing.allocator;
    const r = nominalRenderer();

    var rt = Runtime(RowFitState, RowFitMsg).init(gpa, .{}, rowFitUpdate, rowFitView);
    defer rt.deinit();

    const btn_w = r.measureText("ok", 16).width + 24;

    // Narrow: the label cannot fit, so it gives up room and the button keeps
    // its size and lands flush against the column's right edge.
    {
        var f = try rt.frame(.{ .w = 240, .h = 200 }, r);
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 1), f.hits.len);
        const b = f.hits[0].rect;
        try std.testing.expectApproxEqAbs(btn_w, b.w, 0.5);
        try std.testing.expectApproxEqAbs(@as(f32, 220), b.x + b.w, 0.5);
    }

    // Wide, unwrapped: nothing competes, so the button follows the label
    // instead of being pushed to an edge.
    {
        rt.state.wide = true;
        var f = try rt.frame(.{ .w = 2100, .h = 200 }, r);
        defer f.deinit();
        const b = f.hits[0].rect;
        try std.testing.expectApproxEqAbs(btn_w, b.w, 0.5);
        try std.testing.expect(b.x + b.w < 1900);
    }
}

test "a press owned by one region cannot dispatch its neighbour" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f.deinit();

    const minus = f.hits[0].rect;
    const plus = f.hits[1].rect;
    const on_minus: [2]f32 = .{ minus.x + 5, minus.y + 5 };
    const on_plus: [2]f32 = .{ plus.x + 5, plus.y + 5 };

    var press: Press(TMsg) = .{};
    press.down(&f, on_minus);
    try std.testing.expect(press.waiting());
    // Released over the neighbour: the neighbour does not get the click.
    try std.testing.expect(press.up(on_plus) == null);
    try std.testing.expect(!press.waiting());

    // A stray release afterwards must not resurrect the claim.
    try std.testing.expect(press.up(on_plus) == null);
}

test "a press that started on empty space claims nothing" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f.deinit();

    const plus = f.hits[1].rect;
    var press: Press(TMsg) = .{};
    press.down(&f, .{ 399, 199 }); // nothing there
    try std.testing.expect(!press.waiting());
    try std.testing.expect(press.up(.{ plus.x + 5, plus.y + 5 }) == null);
}

test "a press released inside its own region fires exactly once" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f.deinit();

    const minus = f.hits[0].rect;
    const p: [2]f32 = .{ minus.x + 5, minus.y + 5 };

    var press: Press(TMsg) = .{};
    press.down(&f, p);
    try std.testing.expectEqual(TMsg.dec, press.up(p).?);
    // One pair, one message.
    try std.testing.expect(press.up(p) == null);
}

// A view whose button really does move when the model changes: the spacer
// above it is sized from `n`, so a repaint puts the button somewhere else.
fn reflowView(s: *TState, ui: *Ui(TMsg)) *Element(TMsg) {
    const spacer = ui.rect(.{ .width = 10, .height = 10 });
    spacer.height = 10 + @as(f32, @floatFromInt(@mod(s.n, 4))) * 20;
    const b = ui.button(.{ .label = "-", .msg = .dec, .width = 40 });
    return ui.column(.{ .children = &.{ spacer, b } });
}

test "a press survives a repaint that reflows the frame" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TState, TMsg).init(gpa, .{}, tUpdate, reflowView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    const pressed = f.hits[0].rect;
    const p: [2]f32 = .{ pressed.x + 5, pressed.y + 5 };

    var press: Press(TMsg) = .{};
    press.down(&f, p);
    f.deinit(); // the frame that was pressed is gone

    // The model changed, so the button moved down by 60px.
    rt.state.n = 3;
    var f2 = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    try std.testing.expectEqual(pressed.y + 60, f2.hits[0].rect.y);
    // Nothing is under the pointer in the new frame...
    try std.testing.expect(f2.hitTest(p) == null);
    // ...and the claim was copied out of the old one, so the region that was
    // pressed still owns the release.
    try std.testing.expectEqual(TMsg.dec, press.up(p).?);
}

const BandM = enum { noop };

/// Fails exactly ONE allocation, then behaves normally. std.testing.FailingAllocator is
/// permanent: once it trips, every later allocation fails too.
const OneShot = struct {
    child: Allocator,
    fail_at: usize,
    attempts: usize = 0,

    fn allocator(self: *OneShot) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShot = @ptrCast(@alignCast(ctx));
        self.attempts += 1;
        if (self.attempts == self.fail_at) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShot = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShot = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShot = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn bandUpdate(_: *u8, _: BandM) Action(BandM) {
    return .{};
}

fn bandView(s: *u8, ui: *Ui(BandM)) *Element(BandM) {
    var kids: [200]*Element(BandM) = undefined;
    const n: usize = if (s.* == 0) 1 else kids.len;
    for (kids[0..n], 0..) |*k, i| k.* = ui.text(.{ .label = ui.fmt("{d}", .{i}), .size = 12 });
    return ui.column(.{ .children = kids[0..n] });
}

test "a failure raised outside a build survives the frame reset" {
    // The runner discovers a bad theme file BETWEEN frames, so its failure
    // cannot live in per-build state: `frame()` zeroes that on entry. Keep the
    // two lifetimes apart and the band still draws.
    const gpa = std.testing.allocator;
    var rt = Runtime(u8, BandM).init(gpa, 0, bandUpdate, bandView);
    defer rt.deinit();

    rt.ui.failExternal(.theme, "theme.zon 3:11: {s}", .{"expected 'u32'"});

    var f = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f.deinit();

    var band = false;
    for (f.prims) |p| switch (p) {
        .quad => |q| {
            if (q.rect.y == 0 and q.rect.h == band_h) band = true;
        },
        else => {},
    };
    try std.testing.expect(band);
    try std.testing.expectEqualStrings("theme.zon 3:11: expected 'u32'", rt.ui.failMessage());

    // ...and it is not sticky: clear it and the next frame is clean.
    rt.ui.clearExternal();
    var f2 = try rt.frame(.{ .w = 400, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    var band2 = false;
    for (f2.prims) |p| switch (p) {
        .quad => |q| {
            if (q.rect.y == 0 and q.rect.h == band_h) band2 = true;
        },
        else => {},
    };
    try std.testing.expect(!band2);
}

test "a failed layout allocation paints the error band" {
    // `failed` is cleared at the top of every build, so it cannot be injected
    // from outside: the only honest test makes an allocation genuinely fail,
    // and the failure has to be a single one, or the frame cannot record the
    // band it is supposed to draw.
    const gpa = std.testing.allocator;
    var found_at: ?usize = null;
    var at: usize = 1;
    while (at < 80) : (at += 1) {
        var one = OneShot{ .child = gpa, .fail_at = at };
        var rt = Runtime(u8, BandM).init(one.allocator(), 0, bandUpdate, bandView);
        defer rt.deinit();

        // Warm the arenas with a small view so the induced failure lands on
        // the growth the oversized view needs, not on the first chunk.
        var warm = try rt.frame(.{ .w = 200, .h = 100 }, nominalRenderer());
        warm.deinit();
        rt.state = 1;

        var f = rt.frame(.{ .w = 200, .h = 100 }, nominalRenderer()) catch continue;
        defer f.deinit();

        var band = false;
        var msg = false;
        for (f.prims) |p| switch (p) {
            .quad => |q| {
                if (q.rect.y == 0 and q.rect.h == band_h) switch (q.fill) {
                    .solid => |c| {
                        if (c.r == band_bg.r and c.g == band_bg.g and c.b == band_bg.b) band = true;
                    },
                    else => {},
                };
            },
            .text => |t| {
                if (std.mem.indexOf(u8, t.bytes, "render failed") != null) msg = true;
            },
            else => {},
        };
        if (band and msg) {
            found_at = at;
            break;
        }
    }
    if (found_at == null) return error.NoErrorBand;
}

// --- disabled + keyed children -------------------------------------------

const KMsg = enum { first, second };
const KMode = enum { normal, swapped, only_a };

const KState = struct {
    mode: KMode = .normal,
    disabled: bool = false,
};

fn kUpdate(_: *KState, _: KMsg) Action(KMsg) {
    return .{};
}

fn gradView(_: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const box = ui.rect(.{ .width = 80, .height = 40, .style = .{ .bg = Fill.vgrad(ui.theme.accent, ui.theme.bg), .border = Fill.hgrad(ui.theme.accent, ui.theme.text_muted) } });
    const label = ui.text(.{ .label = "grad", .size = 12, .style = .{ .color = Fill.hgrad(ui.theme.accent, ui.theme.text_muted) } });
    return ui.column(.{ .children = &.{ box, label } });
}

fn kView(s: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button(.{ .label = "a", .msg = .first, .key = 1 });
    const b = ui.button(.{ .label = "b", .msg = .second, .key = 2, .disabled = s.disabled });
    return switch (s.mode) {
        .normal => ui.column(.{ .children = &.{ a, b } }),
        .swapped => ui.column(.{ .children = &.{ b, a } }),
        .only_a => ui.column(.{ .children = &.{a} }),
    };
}

/// No keys: the rect-based path, which must keep working exactly as before.
fn plainView(s: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button(.{ .label = "a", .msg = .first, .disabled = s.disabled });
    return a;
}

fn parentOffView(_: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button(.{ .label = "a", .msg = .first });
    const b = ui.button(.{ .label = "b", .msg = .second });
    const col = ui.column(.{ .children = &.{ a, b }, .disabled = true }); // the container is off; the buttons never said so
    return col;
}

fn dupView(_: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button(.{ .label = "a", .msg = .first, .key = 7 });
    const b = ui.button(.{ .label = "b", .msg = .second, .key = 7 });
    return ui.column(.{ .children = &.{ a, b } });
}

test "a disabled element claims no press but still occupies the list" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, kView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();
    const pb = f.hits[1].rect;
    const p: [2]f32 = .{ pb.x + 5, pb.y + 5 };
    try std.testing.expectEqual(KMsg.second, f.hitTest(p).?);

    rt.state.disabled = true;
    var f2 = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    // Still recorded, because a control that vanished would let clicks
    // through to whatever it covers...
    try std.testing.expectEqual(@as(usize, 2), f2.hits.len);
    try std.testing.expect(!f2.hits[1].active);
    // ...but it claims nothing.
    try std.testing.expect(f2.hitTest(p) == null);
    try std.testing.expect(f2.hit(p) == null);
}

test "disabled inherits from a container" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, parentOffView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();
    // The buttons themselves were never marked; only the column was.
    try std.testing.expectEqual(@as(usize, 2), f.hits.len);
    for (f.hits) |h| try std.testing.expect(!h.active);
    const p: [2]f32 = .{ f.hits[0].rect.x + 5, f.hits[0].rect.y + 5 };
    try std.testing.expect(f.hitTest(p) == null);
}

test "a press in flight is cancelled when its element goes inert" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, plainView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    const p: [2]f32 = .{ f.hits[0].rect.x + 5, f.hits[0].rect.y + 5 };
    rt.press.down(&f, p);
    f.deinit();
    try std.testing.expect(rt.press.waiting());

    rt.state.disabled = true;
    var f2 = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    // Releasing over a control that went disabled must not fire its message.
    try std.testing.expect(!rt.press.waiting());
    try std.testing.expect(rt.press.up(p) == null);
}

test "a keyed press follows its element through a reorder" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, kView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    const pb = f.hits[1].rect; // "b", key 2
    rt.press.down(&f, .{ pb.x + 5, pb.y + 5 });
    f.deinit();

    // The list reorders under the press: "b" is now the first row and "a"
    // occupies the rect that was pressed.
    rt.state.mode = .swapped;
    var f2 = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f2.deinit();

    var new_b: ?Rect = null;
    for (f2.hits) |h| {
        if (h.key) |k| if (k == 2) {
            new_b = h.rect;
        };
    }
    const nb = new_b.?;
    // Releasing at b's NEW position still fires b: identity, not geometry.
    try std.testing.expectEqual(KMsg.second, rt.press.up(.{ nb.x + 5, nb.y + 5 }).?);
}

test "a keyed press is dropped when its element disappears" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, kView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    const pb = f.hits[1].rect;
    rt.press.down(&f, .{ pb.x + 5, pb.y + 5 });
    f.deinit();
    try std.testing.expect(rt.press.waiting());

    rt.state.mode = .only_a;
    var f2 = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    // Whatever slid into that slot must not receive the click.
    try std.testing.expect(!rt.press.waiting());
    try std.testing.expect(rt.press.up(.{ pb.x + 5, pb.y + 5 }) == null);
}

test "duplicate keys draw the error band instead of failing the frame" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, dupView);
    defer rt.deinit();

    // A colliding key is a bug in `view`, not a reason to take the app down:
    // the frame still comes back usable and the band names the fault.
    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 2), f.hits.len);

    var band = false;
    var named = false;
    for (f.prims) |p| switch (p) {
        .quad => |q| {
            if (q.rect.y == 0 and q.rect.h == band_h) switch (q.fill) {
                .solid => |c| {
                    if (c.r == band_bg.r and c.g == band_bg.g and c.b == band_bg.b) band = true;
                },
                else => {},
            };
        },
        .text => |t| {
            // The detail is the point: "duplicate key" without the value
            // sends the reader hunting; "duplicate key 7" is a grep target.
            if (std.mem.indexOf(u8, t.bytes, "duplicate key 7") != null) named = true;
        },
        else => {},
    };
    try std.testing.expect(band and named);

    // A clean view draws no band, so the flag does not leak across frames.
    var rt2 = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, kView);
    defer rt2.deinit();
    var f2 = try rt2.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    for (f2.prims) |p| switch (p) {
        .quad => |q| {
            if (q.rect.y == 0 and q.rect.h == band_h) switch (q.fill) {
                .solid => |c| try std.testing.expect(!(c.r == band_bg.r and c.g == band_bg.g and c.b == band_bg.b)),
                else => {},
            };
        },
        else => {},
    };
}

test "the band carries a formatted detail, then the kind's own text" {
    const gpa = std.testing.allocator;
    var ui = Ui(BandM).init(gpa);
    defer ui.deinit();

    // No detail: the fallback is the kind's text, so a failure that says
    // nothing specific still says something true.
    ui.failWith(.theme);
    try std.testing.expectEqualStrings("render failed: theme", ui.failMessage());

    // With a detail, that is what paints -- the shape a zon diagnostic takes,
    // which no `switch` over an enum could ever produce.
    ui.failFmt(.theme, "theme.zon {d}:{d}: expected 'u32'", .{ 3, 11 });
    try std.testing.expectEqualStrings("theme.zon 3:11: expected 'u32'", ui.failMessage());

    // Longer than the buffer is truncated rather than corrupt: the band must
    // not be able to fail while reporting a failure.
    const long_buf: [232]u8 = @splat('x');
    const long: []const u8 = &long_buf;
    ui.failFmt(.theme, "{s}", .{long});
    try std.testing.expectEqual(ui.fail_buf.len, ui.failMessage().len);

    // A later failure with no detail must not inherit the previous text.
    ui.failWith(.layout_allocation);
    try std.testing.expectEqualStrings("render failed: layout allocation", ui.failMessage());
}

fn themeFailView(_: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    // The shape a zon diagnostic takes: file, line, column, reason. No switch
    // over an enum can produce this, which is why the band grew a slot that
    // holds formatted text instead of looking the reason up.
    ui.failFmt(.theme, "theme.zon {d}:{d}: expected 'u32'", .{ 3, 11 });
    return ui.button(.{ .label = "x", .msg = .first });
}

test "a theme diagnostic reaches the band, file and line intact" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, themeFailView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 380, .h = 230 }, nominalRenderer());
    defer f.deinit();

    var band = false;
    var named = false;
    for (f.prims) |p| switch (p) {
        .quad => |q| {
            if (q.rect.y == 0 and q.rect.h == band_h) switch (q.fill) {
                .solid => |c| {
                    if (c.r == band_bg.r and c.g == band_bg.g and c.b == band_bg.b) band = true;
                },
                else => {},
            };
        },
        .text => |t| {
            if (std.mem.indexOf(u8, t.bytes, "theme.zon 3:11") != null) named = true;
        },
        else => {},
    };
    // Both halves: the banner is drawn AND it names where the file is wrong.
    // A band saying only "theme error" would send its reader to the file with
    // nothing to aim at, which is the whole reason this slot exists.
    try std.testing.expect(band and named);

    // A bad theme keeps the app drawing: the frame is still usable, with its
    // hit regions intact, because a broken theme file is not a broken window.
    try std.testing.expectEqual(@as(usize, 1), f.hits.len);
}

test "a long message is cut to the band rather than pushing the frame" {
    const gpa = std.testing.allocator;
    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, dupView);
    defer rt.deinit();

    // A window too narrow for the message: the band keeps one line and loses
    // characters, because a wrapped band would change layout as a side effect
    // of reporting a bug.
    const narrow = Size{ .w = 60, .h = 120 };
    var f = try rt.frame(narrow, nominalRenderer());
    defer f.deinit();

    const full = rt.ui.failMessage();
    try std.testing.expect(std.mem.indexOf(u8, full, "duplicate key") != null);

    var band = false;
    var band_text: ?[]const u8 = null;
    var band_size: f32 = 0;
    for (f.prims) |p| switch (p) {
        .quad => |q| {
            if (q.rect.y == 0 and q.rect.h == band_h) band = true;
        },
        // The band paints its line after the content, so the first text after
        // the band quad is the band's own.
        .text => |t| if (band and band_text == null) {
            band_text = t.bytes;
            band_size = t.size;
        },
        else => {},
    };
    try std.testing.expect(band);
    const text = band_text orelse return error.NoBand;

    // Cut, not wrapped: what paints is a strict prefix of the message that did
    // not fit, and it fits the window less a 6px gutter on each side. Grepping
    // the painted line for a word would be testing the truncation length, not
    // the property -- at 60px wide only six characters survive.
    try std.testing.expect(text.len > 0);
    try std.testing.expect(text.len < full.len);
    try std.testing.expect(std.mem.startsWith(u8, full, text));
    try std.testing.expect(nominalTextMetrics(text, band_size).width <= narrow.w - 12);

    // The cut text is confined to the band's own line: the frame underneath
    // lays out exactly as it would in a window wide enough for the message.
    var wide = try rt.frame(.{ .w = 400, .h = 120 }, nominalRenderer());
    defer wide.deinit();
    try std.testing.expectEqual(f.hits.len, wide.hits.len);
    for (f.hits, wide.hits) |lo, hi| {
        try std.testing.expectEqual(lo.rect.y, hi.rect.y);
        try std.testing.expectEqual(lo.rect.h, hi.rect.h);
    }
}

test "a gradient override paints instead of the flat colour" {
    const gpa = std.testing.allocator;

    var rt = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, gradView);
    defer rt.deinit();
    var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
    defer f.deinit();

    // A `_grad` field must actually reach the prims: three slots here (bg,
    // border, text), and if `pick` ever stops consulting them the frame goes
    // quietly back to flat colour, which no other test would notice because
    // the rasteriser is covered directly in software.zig.
    var grads: usize = 0;
    for (f.prims) |p| switch (p) {
        .quad => |q| if (!q.fill.isSolid()) {
            grads += 1;
        },
        .rrect => |q| if (!q.fill.isSolid()) {
            grads += 1;
        },
        .text => |t| if (!t.fill.isSolid()) {
            grads += 1;
        },
        .frost => {},
        // A halo has one flat colour by design; it is a ramp in ALPHA, not a
        // gradient fill, so it must not count toward the gradient census.
        .halo => {},
        // A blit carries pixels, not a fill, so it is not a gradient either.
        .blit => {},
        // An icon's tint was flattened to one RGB at build time, so whatever
        // fill the caller passed has already been spent.
        .icon => {},
        // An image carries no fill at all; it is drawn as decoded.
        .image => {},
    };
    try std.testing.expect(grads >= 3);

    // And nothing without a gradient gets one: the override is opt-in.
    var rt2 = Runtime(KState, KMsg).init(gpa, .{}, kUpdate, kView);
    defer rt2.deinit();
    var f2 = try rt2.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
    defer f2.deinit();
    for (f2.prims) |p| switch (p) {
        .quad => |q| try std.testing.expect(q.fill.isSolid()),
        .rrect => |q| try std.testing.expect(q.fill.isSolid()),
        .text => |t| try std.testing.expect(t.fill.isSolid()),
        .halo => {},
        .frost => {},
        .blit => {},
        .icon => {},
        .image => {},
    };
}

// ---------------------------------------------------------------------------
// theme files
// ---------------------------------------------------------------------------

test "a key code is wide enough to survive SDLK_LEFT" {
    // 0x40000050 is SDLK_LEFT, and SDLK_SCANCODE_MASK is 1 << 30. While the
    // event carried a u8 this arrived as 'P' -- nothing caught it because no
    // key was bound yet, so the only symptom would have been a shortcut that
    // fired on an arrow key.
    const left: Key = .{ .named = .left, .code = 0x40000050 };
    try std.testing.expectEqual(@as(u32, 0x40000050), left.code);
    try std.testing.expectEqual(@as(u32, 32), @bitSizeOf(@TypeOf(left.code)));
    try std.testing.expectEqual(@as(u8, 'P'), @as(u8, @truncate(left.code)));

    // `named` is a convenience, not a filter: an unlisted key still arrives
    // whole, which is what lets an app bind a character or an IME key.
    const unlisted: Key = .{ .code = 0x010000E9 };
    try std.testing.expectEqual(@as(?Named, null), unlisted.named);
    try std.testing.expectEqual(@as(u32, 0x010000E9), unlisted.code);
}

test "modifier flags pack into one byte with no padding" {
    // A packed struct keeps this at four bits; a plain struct would make the
    // event 4 bytes wider and, worse, would not be comparable with ==.
    const held: Mods = .{ .shift = true, .ctrl = true, .alt = true, .gui = true };
    try std.testing.expectEqual(@as(u4, 0b1111), @as(u4, @bitCast(held)));
    try std.testing.expectEqual(@as(Mods, .{ .ctrl = true }), Mods{ .ctrl = true });
    try std.testing.expect(Mods{ .ctrl = true } != Mods{ .shift = true });
}

test "a style is named once and inline fields still win" {
    // The complaint this answers: a style could be named OR extended but not both,
    // because the two went through different fields and neither composed.
    const M = void;
    var r: Ui(M) = .init(std.testing.allocator);
    defer r.deinit();

    // "heading" is built in. `pad` is set beside the name to prove the inline
    // field survives the merge rather than being overwritten by it.
    const named_only = r.text(.{ .label = "x", .style = .{ .name = "heading" } });
    const via_name = r.text(.{ .label = "x", .style = .{ .name = "heading" } });
    const via_class = r.text(.{ .label = "x", .style = .{ .class = "heading" } });
    const both = r.text(.{ .label = "x", .style = .{ .name = "heading", .pad = 9 } });

    // Assert on the GEOMETRY, not on `style()`: `size` and `weight` are baked into
    // the text geometry before `finish` runs, so they never appear in a Style at
    // all. Reading them off `style()` is the mistake this comment exists to stop
    // someone repeating.
    const a = named_only.geometry.text.size;
    const b = via_name.geometry.text.size;
    const c = via_class.geometry.text.size;
    // The built-in `heading` style supplies a size, and `text` falls back to 14
    // only when nothing did.
    try std.testing.expect(a != 14);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(a, c);

    // Inline wins where it is written, and the named style still fills the rest.
    try std.testing.expectEqual(@as(f32, 9), both.pad);
    try std.testing.expectEqual(a, both.geometry.text.size);
}

test "an unknown style name reports instead of painting the floor" {
    // The bug class: a misspelled name resolved to null and merged nothing, so
    // the element rendered with the compiled defaults and said nothing. A typo
    // and a working name looked identical.
    const M = void;
    var r: Ui(M) = .init(std.testing.allocator);
    defer r.deinit();

    _ = r.text(.{ .label = "x", .style = .{ .name = "heding" } });
    try std.testing.expect(r.failed);
    try std.testing.expectEqual(FailKind.style, r.fail_kind);
    // The band names the style AND which spelling was used.
    const band = r.fail_buf[0..r.fail_len];
    try std.testing.expect(std.mem.indexOf(u8, band, "heding") != null);
    try std.testing.expect(std.mem.indexOf(u8, band, "style.name") != null);
}

test "a known style name raises no band" {
    // The other half: reporting must not fire on success, or every themed app
    // shows a permanent failure line.
    const M = void;
    var r: Ui(M) = .init(std.testing.allocator);
    defer r.deinit();

    _ = r.text(.{ .label = "x", .style = .{ .name = "heading" } });
    try std.testing.expect(!r.failed);
}

test "name and class are the same slot, either spelling" {
    // Both are aliases of one thing, so `refName` returns the name whichever
    // field carried it. Two DIFFERENT values is caught by the assert inside
    // `refName`, which a test cannot catch without a panic handler -- the
    // agreeing case is the contract every caller relies on.
    try std.testing.expectEqualStrings("heading", (Style{ .name = "heading" }).refName().?);
    try std.testing.expectEqualStrings("heading", (Style{ .class = "heading" }).refName().?);
    try std.testing.expectEqualStrings("heading", (Style{ .name = "heading", .class = "heading" }).refName().?);
    // Neither set is not a reference at all.
    try std.testing.expectEqual(@as(?[]const u8, null), (Style{}).refName());
}

test "a separator takes a caller style instead of always the theme border" {
    // The bug: `separator` built its rect with a hardcoded border colour and never
    // called `finish`, so `.style` parsed, sat on the opts struct,
    // and reached nothing. Adding the fields without this test would have shipped
    // two more decorative options.
    const M = void;
    var r: Ui(M) = .init(std.testing.allocator);
    defer r.deinit();

    // Default: the theme border, because that is what an unstyled rule should be.
    const plain = r.separator(.{});
    try std.testing.expect(plain.bg != null);

    // Caller overrides the fill.
    const red = Color.rgbHex(0xff0000);
    const styled = r.separator(.{ .style = .{ .bg = .{ .solid = red } } });
    try std.testing.expect(std.meta.eql(styled.bg.?.solid, red));

    // And a named style reaches it too, not just an inline field.
    _ = r.text(.{ .label = "x", .style = .{ .name = "heading" } });
    const named = r.separator(.{ .style = .{ .name = "heading" } });
    // `heading` supplies a size/face rather than a bg, so the border default stands
    // -- what matters is that the lookup ran and did not raise a miss band.
    try std.testing.expect(!r.failed);
    try std.testing.expect(named.bg != null);
}

test "a progress bar takes a caller style" {
    // Same shape as the separator: `progress` delegates to `bar` and used to drop
    // the style on the way, so a themed track was unreachable.
    const M = void;
    var r: Ui(M) = .init(std.testing.allocator);
    defer r.deinit();

    const accent = Color.rgbHex(0x00ff00);
    const e = r.progress(.{ .value = 0.5, .style = .{ .color = .{ .solid = accent } } });
    try std.testing.expect(std.meta.eql(e.color.?.solid, accent));
}

test "every Style field is honoured by applyStyle and mergeStyle" {
    // A field-by-field merge is a list that a new field can be left off, and
    // the omission is invisible: the element simply keeps its default and
    // nothing reports it. `halo` was dropped exactly that way -- a card asked
    // for a shadow, the frame said "0 halo(s)", and no test complained.
    // Iterating the fields makes the next one fail to compile instead.
    const S = Style;
    var full: S = .{};
    inline for (@typeInfo(S).@"struct".fields) |f| {
        // `bool` fields are not optional -- `stroke` is a plain flag, not a
        // tri-state -- so the unwrap has to be conditional or the whole test
        // fails to compile with "access of union field 'optional' while field
        // 'bool' is active".
        const is_opt = @typeInfo(f.type) == .optional;
        const Child = if (is_opt) @typeInfo(f.type).optional.child else f.type;
        const v: f.type = if (!is_opt) switch (Child) {
            bool => true,
            else => @compileError("non-optional Style field '" ++ f.name ++ "' of type " ++
                @typeName(Child) ++ " needs a value here"),
        } else switch (Child) {
            Color => .{ .r = 1, .g = 2, .b = 3, .a = 4 },
            Fill => .{ .solid = .{ .r = 5, .g = 6, .b = 7, .a = 8 } },
            f32 => 7,
            u16 => 3,
            u8 => 2,
            []const u8 => "probe",
            bool => true,
            Halo => .{ .color = .{ .r = 9, .g = 10, .b = 11, .a = 12 }, .blur = 3, .spread = 1, .offset = .{ 1, 2 } },
            Frost => .{ .blur = 5 },
            else => @compileError("new Style field '" ++ f.name ++ "' of type " ++ @typeName(Child) ++
                " needs a value here, and a matching line in applyStyle and mergeStyle"),
        };
        @field(full, f.name) = v;
    }

    // applyStyle: a wholesale set
    var a: Element(void) = .{ .geometry = .{ .rect = {} } };
    a.applyStyle(full);
    inline for (@typeInfo(S).@"struct".fields) |f| {
        const is_opt2 = @typeInfo(f.type) == .optional;
        // `margin` is a RESOLVER, not a stored field: applyStyle fans it out
        // into the four sides, and an Element has no `margin` to compare with.
        // Its effect is covered by asserting the sides below.
        if (comptime std.mem.eql(u8, f.name, "margin")) continue;
        // `size` and `weight` are read when the geometry is BUILT (`text()`
        // picks the size, the face picks the instance), so neither is a field
        // on an Element to compare. Covered by the text tests instead.
        if (comptime std.mem.eql(u8, f.name, "size")) continue;
        if (comptime std.mem.eql(u8, f.name, "weight")) continue;
        // `name` and `class` are REFERENCES to a theme style, resolved in
        // `finish` before the merge. They name where values come from, so
        // there is nothing of them to store on the Element.
        if (comptime std.mem.eql(u8, f.name, "name")) continue;
        if (comptime std.mem.eql(u8, f.name, "class")) continue;
        if (!is_opt2) {
            try std.testing.expectEqual(@field(full, f.name), @field(a, f.name));
        } else if (@typeInfo(f.type).optional.child == f32) {
            // applyStyle defaults an absent radius/pad, so compare as optional
            try std.testing.expect(@field(a, f.name) == @field(full, f.name).?);
        } else {
            try std.testing.expect(std.meta.eql(@field(a, f.name), @field(full, f.name).?));
        }
    }

    // The shorthand really did fan out: one `margin` set every side.
    try std.testing.expectEqual(@as(f32, 7), a.margin_left);
    try std.testing.expectEqual(@as(f32, 7), a.margin_top);

    // mergeStyle: only the fields the caller set, all of which are set here
    var m: Element(void) = .{ .geometry = .{ .rect = {} } };
    m.mergeStyle(full);
    inline for (@typeInfo(S).@"struct".fields) |f| {
        const is_opt3 = @typeInfo(f.type) == .optional;
        // Same three non-stored fields as above: none of them lands on an
        // Element, so there is nothing here to compare.
        if (comptime std.mem.eql(u8, f.name, "margin")) continue;
        if (comptime std.mem.eql(u8, f.name, "size")) continue;
        if (comptime std.mem.eql(u8, f.name, "weight")) continue;
        // `name` and `class` are REFERENCES to a theme style, resolved in
        // `finish` before the merge. They name where values come from, so
        // there is nothing of them to store on the Element.
        if (comptime std.mem.eql(u8, f.name, "name")) continue;
        if (comptime std.mem.eql(u8, f.name, "class")) continue;
        if (!is_opt3) {
            try std.testing.expectEqual(@field(full, f.name), @field(m, f.name));
        } else if (@typeInfo(f.type).optional.child == f32) {
            try std.testing.expect(@field(m, f.name) == @field(full, f.name).?);
        } else {
            try std.testing.expect(std.meta.eql(@field(m, f.name), @field(full, f.name).?));
        }
    }
}

// A rounded control's bounding box is not its shape. Hit testing used to claim
// the full rect, so a press on the empty corner of a rounded card lit it -- and
// with overlap it would have claimed a click meant for whatever is behind.
const RoundState = struct { presses: u32 = 0 };
const RoundMsg = enum { press };
fn roundUpdate(st: *RoundState, m: RoundMsg) Action(RoundMsg) {
    if (m == .press) st.presses += 1;
    return .{};
}
fn roundView(_: *RoundState, ui: *Ui(RoundMsg)) *Element(RoundMsg) {
    return ui.button(.{
        .label = "rounded",
        .msg = .press,
        .width = 120,
        .height = 60,
        .key = 1,
        .style = .{ .radius = 30 },
    });
}

test "a rounded control is not claimed by its empty corner" {
    const gpa = std.testing.allocator;
    var rt = Runtime(RoundState, RoundMsg).init(gpa, .{}, roundUpdate, roundView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();
    // The container itself now scrolls -- its content is taller than the 16px
    // box it was given -- so it records a region and a thumb besides the
    // button. What this test is about is the BUTTON's claim, so count
    // message-bearing regions rather than all of them.
    var n_msg: usize = 0;
    var r: Rect = undefined;
    for (f.hits) |hit| if (hit.msg != null) {
        n_msg += 1;
        r = hit.rect;
    };
    try std.testing.expectEqual(@as(usize, 1), n_msg);
    // The radius the rasteriser would clamp to, so the test states the shape it
    // is asserting against: half the short side.
    try std.testing.expectEqual(@as(f32, 30), f.hits[0].radius);

    const centre: [2]f32 = .{ r.x + r.w / 2, r.y + r.h / 2 };
    try std.testing.expectEqual(RoundMsg.press, f.hitTest(centre).?);

    // 1px in from the corner: inside the rect, outside the quarter circle.
    const corner: [2]f32 = .{ r.x + 1, r.y + 1 };
    try std.testing.expect(r.contains(corner));
    try std.testing.expectEqual(@as(?RoundMsg, null), f.hitTest(corner));

    // A press there claims nothing, so it can never produce a message on release.
    rt.press.down(&f, corner);
    try std.testing.expect(!rt.press.waiting());
    try std.testing.expectEqual(@as(?RoundMsg, null), rt.press.up(corner));

    // The centre still works, so the test is not passing by refusing everything.
    rt.press.down(&f, centre);
    try std.testing.expectEqual(RoundMsg.press, rt.press.up(centre).?);
}

test "a square control still claims its full rect" {
    const gpa = std.testing.allocator;
    var rt = Runtime(RoundState, RoundMsg).init(gpa, .{}, roundUpdate, sqView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();
    const r = f.hits[0].rect;
    try std.testing.expectEqual(@as(f32, 0), f.hits[0].radius);
    try std.testing.expectEqual(RoundMsg.press, f.hitTest(.{ r.x + 1, r.y + 1 }).?);
}

fn sqView(_: *RoundState, ui: *Ui(RoundMsg)) *Element(RoundMsg) {
    return ui.button(.{ .label = "square", .msg = .press, .width = 120, .height = 60, .key = 1 });
}

// ---------------------------------------------------------------------------
// focus: derived, like hover and press
// ---------------------------------------------------------------------------

const FocusState = struct {};
const FocusMsg = enum { nop };

fn focusUpdate(m: *FocusState, msg: FocusMsg) Action(FocusMsg) {
    _ = m;
    _ = msg;
    return .{};
}

/// One button, optionally keyed. `focusable` without a key is the case that matters: focus
/// names an identity, so an anonymous element cannot hold it.
fn focusView(m: *FocusState, ui: *Ui(FocusMsg)) *Element(FocusMsg) {
    _ = m;
    const b = ui.button(.{ .label = "ok", .msg = .nop });
    b.focusable = true;
    b.radius = 8; // a square border is four quads; a rounded one is a single stroke
    b.key = focus_key;
    return ui.column(.{ .children = &.{b} });
}

fn anonymousView(m: *FocusState, ui: *Ui(FocusMsg)) *Element(FocusMsg) {
    _ = m;
    const b = ui.button(.{ .label = "ok", .msg = .nop });
    b.radius = 8;
    b.focusable = true; // focusable, but no key to name it by
    return ui.column(.{ .children = &.{b} });
}

const focus_key: u64 = 7;

// ---------------------------------------------------------------------------
// activation: derived from the message, never declared
// ---------------------------------------------------------------------------

const ActState = struct {};
const ActMsg = enum { fire };

fn actUpdate(m: *ActState, msg: ActMsg) Action(ActMsg) {
    _ = m;
    _ = msg;
    return .{};
}

const act_key_ok: u64 = 1;
const act_key_field: u64 = 2;
const act_key_off: u64 = 3;

fn actView(m: *ActState, ui: *Ui(ActMsg)) *Element(ActMsg) {
    _ = m;
    const ok = ui.button(.{ .label = "ok", .msg = .fire });
    ok.focusable = true;
    ok.key = act_key_ok;

    // The text-field shape: focusable and keyed, but carrying NO message.
    // Activation is derived from the message, so Enter has nothing to fire
    // here and falls through to `on_key`, which is the only code that knows
    // what Enter means inside a value.
    const field = ui.text(.{ .label = "abc", .size = 12 });
    field.focusable = true;
    field.key = act_key_field;

    // Focusable, keyed, messaged -- and inert.
    const off = ui.button(.{ .label = "off", .msg = .fire });
    off.focusable = true;
    off.key = act_key_off;
    off.disabled = true;

    return ui.column(.{ .children = &.{ ok, field, off } });
}

const ScMsg = enum { save, new_doc, all_done };

const sc_list = &.{
    Shortcut(ScMsg){ .key = ShortcutKey.char('s'), .ctrl = true, .msg = .save },
    Shortcut(ScMsg){ .key = ShortcutKey.char('n'), .ctrl = true, .shift = true, .msg = .new_doc },
    Shortcut(ScMsg){ .key = .{ .named = .f5 }, .msg = .all_done },
};

test "a shortcut matches the whole chord, not just the key" {
    const ctrl_s: Key = .{ .code = 's', .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(ScMsg.save, shortcutFor(ScMsg, sc_list, ctrl_s, false).?);

    // The same key with no ctrl is somebody typing an `s`.
    const plain_s: Key = .{ .code = 's' };
    try std.testing.expect(shortcutFor(ScMsg, sc_list, plain_s, false) == null);

    // Ctrl+Shift+S is a different chord, not a synonym for Ctrl+S. A rule that
    // ignored shift would make the two impossible to distinguish.
    const ctrl_shift_s: Key = .{ .code = 'S', .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expect(shortcutFor(ScMsg, sc_list, ctrl_shift_s, false) == null);

    // ...and the one that DID bind shift matches, capital and all.
    const ctrl_shift_n: Key = .{ .code = 'N', .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expectEqual(ScMsg.new_doc, shortcutFor(ScMsg, sc_list, ctrl_shift_n, false).?);
}

test "a bare binding yields to a text field, a modified one does not" {
    const f5: Key = .{ .named = .f5 };
    try std.testing.expectEqual(ScMsg.all_done, shortcutFor(ScMsg, sc_list, f5, false).?);

    // Every keystroke into a field must reach the field, so an unmodified
    // binding has to stand down while one has focus.
    try std.testing.expect(shortcutFor(ScMsg, sc_list, f5, true) == null);

    // A chord still fires there, or Ctrl+S would stop working in exactly the
    // place people press it most.
    const ctrl_s: Key = .{ .code = 's', .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(ScMsg.save, shortcutFor(ScMsg, sc_list, ctrl_s, true).?);
}

test "shift alone is bare, because Shift+S is how a capital is typed" {
    const sc = Shortcut(ScMsg){ .key = ShortcutKey.char('s'), .shift = true, .msg = .save };
    try std.testing.expect(isBareShortcut(sc));
    // One command modifier is enough to stop being bare.
    const chord = Shortcut(ScMsg){ .key = ShortcutKey.char('s'), .ctrl = true, .msg = .save };
    try std.testing.expect(!isBareShortcut(chord));
}

// ---------------------------------------------------------------------------
// time into paint
// ---------------------------------------------------------------------------

const TimeState = struct { elapsed: f32 = -1, since_input: f32 = -1, n: i32 = 0 };

fn timeUpdate(m: *TimeState, msg: TMsg) Action(TMsg) {
    _ = m;
    _ = msg;
    return .{};
}

fn timeView(m: *TimeState, ui: *Ui(TMsg)) *Element(TMsg) {
    m.elapsed = ui.elapsed;
    m.since_input = ui.since_input;
    return ui.text(.{ .label = "-", .size = 14 });
}

test "the clock reaches paint, so a caret needs no clock of its own" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TimeState, TMsg).init(gpa, .{}, timeUpdate, timeView);
    defer rt.deinit();

    // Nothing has ticked: both read zero rather than a sentinel the app would
    // have to defend against.
    {
        var f = try rt.frame(.{ .w = 100, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(f32, 0), rt.state.elapsed);
        try std.testing.expectEqual(@as(f32, 0), rt.state.since_input);
    }

    // Whatever the runtime holds is what paint sees, unmodified.
    rt.elapsed = 1.25;
    rt.since_input = 0.5;
    {
        var f = try rt.frame(.{ .w = 100, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(f32, 1.25), rt.state.elapsed);
        try std.testing.expectEqual(@as(f32, 0.5), rt.state.since_input);
    }
}

test "activation is derived from the message, so a value control falls through" {
    const gpa = std.testing.allocator;
    var rt = Runtime(ActState, ActMsg).init(gpa, .{}, actUpdate, actView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 200 }, nominalRenderer());
    defer f.deinit();

    // Focusable, named, messaged: Enter and Space reach it.
    try std.testing.expectEqual(ActMsg.fire, f.activate(act_key_ok).?);

    // No message, so nothing to activate. This is how a text field refuses
    // Enter with no special case anywhere in the tree or the runtime.
    try std.testing.expect(f.activate(act_key_field) == null);

    // Inert: it is focused and named, but a disabled control must not fire.
    try std.testing.expect(f.activate(act_key_off) == null);

    // Nothing focused, and a key no region carries.
    try std.testing.expect(f.activate(null) == null);
    try std.testing.expect(f.activate(9999) == null);
}

/// How many prims are filled with exactly `c`.
fn countSolidPrims(prims: anytype, c: Color) usize {
    var n: usize = 0;
    for (prims) |p| switch (p) {
        .quad => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = c })) n += 1;
        },
        .rrect => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = c })) n += 1;
        },
        else => {},
    };
    return n;
}

fn countAccentPrims(prims: anytype, th: Theme) usize {
    var n: usize = 0;
    for (prims) |p| switch (p) {
        .quad => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = th.accent })) n += 1;
        },
        .rrect => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = th.accent })) n += 1;
        },
        else => {},
    };
    return n;
}

test "focus paints the accent border, and only on the element that holds it" {
    const gpa = std.testing.allocator;
    const th = Theme{};

    var rt = Runtime(FocusState, FocusMsg).init(gpa, .{}, focusUpdate, focusView);
    defer rt.deinit();

    {
        var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 0), countAccentPrims(f.prims, th));
    }

    // Somebody else holds focus: still nothing.
    rt.focus = 999;
    {
        var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 0), countAccentPrims(f.prims, th));
    }

    rt.focus = 7;
    {
        var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 1), countAccentPrims(f.prims, th));
    }
}

test "an unkeyed element cannot be focused even when it says it is focusable" {
    const gpa = std.testing.allocator;
    const th = Theme{};
    var rt = Runtime(FocusState, FocusMsg).init(gpa, .{}, focusUpdate, anonymousView);
    defer rt.deinit();

    // Focus is "some key", and this element has none, so no value of rt.focus
    // can match it. The field alone is not a focus claim.
    rt.focus = 0;
    var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 0), countAccentPrims(f.prims, th));
}

const FocusActionState = struct {
    request: ?u64 = null,
    seen: ?u64 = null,
};

fn focusActionUpdate(m: *FocusActionState, msg: FocusMsg) Action(FocusMsg) {
    _ = msg;
    if (m.request) |key| return .{ .focus = .{ .set = key } };
    return .{ .focus = .clear };
}

fn focusActionView(m: *FocusActionState, ui: *Ui(FocusMsg)) *Element(FocusMsg) {
    m.seen = ui.focus;
    const b = ui.button(.{ .label = "ok", .msg = .nop });
    b.focusable = true;
    b.radius = 8;
    b.key = focus_key;
    return ui.column(.{ .children = &.{b} });
}

test "an action moves focus, view can read it, and the ring follows" {
    const gpa = std.testing.allocator;
    const th = Theme{};

    var rt = Runtime(FocusActionState, FocusMsg).init(gpa, .{}, focusActionUpdate, focusActionView);
    defer rt.deinit();

    // Nothing holds focus, and an explicit clear is a no-op rather than an error.
    try std.testing.expectEqual(@as(?u64, null), rt.focus);
    _ = rt.dispatch(.nop);
    try std.testing.expectEqual(@as(?u64, null), rt.focus);

    // The app asks for focus by key; the runtime holds it, view sees it, and
    // the element carrying that key paints the accent border.
    rt.state.request = focus_key;
    _ = rt.dispatch(.nop);
    try std.testing.expectEqual(@as(?u64, focus_key), rt.focus);
    {
        var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?u64, focus_key), rt.state.seen);
        try std.testing.expectEqual(@as(usize, 1), countAccentPrims(f.prims, th));
    }

    // A key no element carries is still held by the runtime -- focusing
    // something that scrolled away is not a bug -- but nothing paints.
    rt.state.request = 999;
    _ = rt.dispatch(.nop);
    try std.testing.expectEqual(@as(?u64, 999), rt.focus);
    {
        var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?u64, 999), rt.state.seen);
        try std.testing.expectEqual(@as(usize, 0), countAccentPrims(f.prims, th));
    }

    // Giving focus up reaches view as null and takes the ring with it.
    rt.state.request = null;
    _ = rt.dispatch(.nop);
    try std.testing.expectEqual(@as(?u64, null), rt.focus);
    {
        var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?u64, null), rt.state.seen);
        try std.testing.expectEqual(@as(usize, 0), countAccentPrims(f.prims, th));
    }
}

const VPState = struct {};
const VPMsg = enum { nop, tap };

fn vpUpdate(_: *VPState, _: VPMsg) Action(VPMsg) {
    return .{};
}

/// Ten 20px rows in a 100px viewport: 200 of content, 100 of view, so the maximum offset is
/// exactly 100 and every row is 20 below the one before it.
fn vpView(_: *VPState, ui: *Ui(VPMsg)) *Element(VPMsg) {
    var kids: [10]*Element(VPMsg) = undefined;
    for (&kids, 0..) |*k, i| {
        k.* = ui.rect(.{ .width = 80, .height = 20, .on_press = .tap, .key = 100 + i });
    }
    // Implicit scroll: the container IS the viewport. A definite height and
    // more content than fits is the whole declaration -- there is no wrapper.
    const col = ui.column(.{ .key = 7, .height = 100, .children = &kids });
    return ui.column(.{ .children = &.{col} });
}

/// The viewport's scroll identity: the column the view builds sits at child 0 of the root,
/// so its identity is one step down the root path.
fn vpKey() u64 {
    return pathChild(scroll_path_root, 0);
}

/// The stack-wrapped view adds one level: stack -> column -> column. Identity is a tree
/// path, so deeper nesting means a deeper key.
fn vpKeyInStack() u64 {
    return pathChild(pathChild(scroll_path_root, 0), 0);
}

fn vpRegion(hits: []const Hit(VPMsg), key: u64) ?Hit(VPMsg) {
    for (hits) |h| {
        // A scrolled container carries its identity in `scroll_id`; an ordinary
        // region carries an app key. Either can be the thing being looked for.
        if (h.scroll_id) |k| if (k == key) return h;
        if (h.key) |k| if (k == key) return h;
    }
    return null;
}

test "a viewport records its content height and translates its content" {
    const gpa = std.testing.allocator;
    var rt = Runtime(VPState, VPMsg).init(gpa, .{}, vpUpdate, vpView);
    defer rt.deinit();

    // Unscrolled: the region tells the wheel how much there is to scroll, and
    // the first row sits at the top of the viewport.
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        const vp = vpRegion(f.hits, vpKey()) orelse return error.NoViewport;
        const sv = vp.scroll orelse return error.NoScrollInfo;
        try std.testing.expectEqual(@as(f32, 200), sv.content_h);
        try std.testing.expectEqual(@as(f32, 100), sv.view_h);
        try std.testing.expectEqual(@as(f32, 0), vpRegion(f.hits, 100).?.rect.y);
    }

    // Offset 40: the first two rows are gone and row 2 has taken row 0's
    // place. A region that scrolled out produces NO hit at all, which is the
    // clip doing its work rather than paint pretending.
    rt.scrollTo(vpKey(), 40);
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?Hit(VPMsg), null), vpRegion(f.hits, 100));
        try std.testing.expectEqual(@as(f32, 0), vpRegion(f.hits, 102).?.rect.y);
    }

    // Offset past the end: paint clamps to content_h - view_h, so the store is
    // allowed to be one frame ahead without painting blank space.
    rt.scrollTo(vpKey(), 9999);
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(f32, 0), vpRegion(f.hits, 105).?.rect.y);
        try std.testing.expectEqual(@as(?Hit(VPMsg), null), vpRegion(f.hits, 104));
    }
}

/// The same viewport, nested inside a stack. A container geometry added after the scroll
/// work has to be walked by `injectScrollOffsets` too.
fn vpStackView(s: *VPState, ui: *Ui(VPMsg)) *Element(VPMsg) {
    const page = vpView(s, ui);
    return ui.stack(.{ .children = &.{page} });
}

test "a viewport inside a stack still receives its offset" {
    const gpa = std.testing.allocator;
    var rt = Runtime(VPState, VPMsg).init(gpa, .{}, vpUpdate, vpStackView);
    defer rt.deinit();

    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(f32, 0), vpRegion(f.hits, 100).?.rect.y);
        try std.testing.expectEqual(@as(f32, 200), vpRegion(f.hits, vpKeyInStack()).?.scroll.?.content_h);
    }

    // Row 0 scrolled out, row 2 took its place. Without the stack arm both
    // assertions read as an unscrolled frame.
    rt.scrollTo(vpKeyInStack(), 40);
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?Hit(VPMsg), null), vpRegion(f.hits, 100));
        try std.testing.expectEqual(@as(f32, 0), vpRegion(f.hits, 102).?.rect.y);
    }
}

test "a font failure names the path in the band" {
    const gpa = std.testing.allocator;
    var rt = Runtime(FocusState, FocusMsg).init(gpa, .{}, focusUpdate, focusView);
    defer rt.deinit();

    // Raised between frames, the way runApp raises a failed load -- so this
    // also re-covers the "external failure survives the frame reset" path for
    // a second prong, not just `.theme`.
    rt.ui.failExternal(.font, "font not found: {s}", .{"src/font.ttf"});
    // Staged, not raised: nothing has failed IN this frame yet, and a stale
    // geometry must not be visible before frame() folds the condition in.
    try std.testing.expect(!rt.ui.failed);

    var f = try rt.frame(.{ .w = 400, .h = 120 }, nominalRenderer());
    defer f.deinit();

    // frame() folds the external condition in, so only now is the detail legal
    // to read. Before the frame it is staged, not raised.
    try std.testing.expectEqualStrings("font not found: src/font.ttf", rt.ui.failMessage());

    var band: usize = 0;
    for (f.prims) |p| switch (p) {
        .quad => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = band_bg })) band += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), band);
}

const TabMsg = enum { a, b, c };
const TabState = struct { disable_mid: bool = false, no_focus: bool = false };

fn tabUpdate(m: *TabState, msg: TabMsg) Action(TabMsg) {
    _ = m;
    _ = msg;
    return .{};
}

/// Document order 1, 2, 3, with 2 optionally disabled, bracketed by one focusable element
/// that has no key and one that is not focusable at all.
fn tabView(s: *TabState, ui: *Ui(TabMsg)) *Element(TabMsg) {
    if (s.no_focus) {
        const plain = ui.button(.{ .label = "plain", .msg = .a, .key = 9 });
        return ui.column(.{ .children = &.{plain} });
    }
    const a = ui.button(.{ .label = "a", .msg = .a, .key = 1 });
    const b = ui.button(.{ .label = "b", .msg = .b, .key = 2, .disabled = s.disable_mid });
    const unkeyed = ui.button(.{ .label = "x", .msg = .c });
    const not_focusable = ui.button(.{ .label = "y", .msg = .c, .key = 4 });
    const c = ui.button(.{ .label = "c", .msg = .c, .key = 3 });
    a.focusable = true;
    b.focusable = true;
    // Focusable and unnamed. Keys are automatic now: the tree path stands in,
    // so this IS landable, and `tabViewUnkeyed` below exposes its identity.
    unkeyed.focusable = true;
    c.focusable = true;
    return ui.column(.{ .children = &.{ a, b, unkeyed, not_focusable, c } });
}

test "tab walks document order, skips a disabled control, and wraps" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TabState, TabMsg).init(gpa, .{}, tabUpdate, tabView);
    defer rt.deinit();

    rt.state.disable_mid = true;
    var x_key: u64 = 0;
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();

        // The unkeyed control's identity is derived, not authored, so the test
        // reads it off the frame rather than hardcoding a hash.
        // Second focusable in document order is the unkeyed one.
        x_key = f.focusStep(1, true) orelse return error.TestUnexpectedResult;
        std.debug.print("\nDISABLED order: ", .{});
        var cur: ?u64 = f.focusStep(null, true);
        while (cur) |c| {
            std.debug.print("{d} ", .{c});
            cur = f.focusStep(c, true);
            if (cur != null and cur.? == 1) break;
        }
        std.debug.print("\n", .{});
        try std.testing.expect(x_key != 1 and x_key != 3);

        // Ascending index is document order, not the reverse order hit() uses.
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(null, true));
        try std.testing.expectEqual(@as(?u64, x_key), f.focusStep(1, true));
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(x_key, true));
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(3, true));

        // Backwards from nowhere starts at the last candidate.
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(null, false));
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(x_key, false));

        // A key that no longer exists is a rebuild, not a dead end.
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(99, true));
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(99, false));

        // 2 is disabled and 4 was never focusable: neither is a candidate.
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(2, true));
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(4, true));
    }

    // Enabled again, the middle control joins the cycle.
    rt.state.disable_mid = false;
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        std.debug.print("\nDIRECT 1->{?d} x->{?d} 2->{?d}\n", .{ f.focusStep(1, true), f.focusStep(x_key, true), f.focusStep(2, true) });
        std.debug.print("\nENABLED order: ", .{});
        var cur2: ?u64 = f.focusStep(null, true);
        while (cur2) |c| {
            std.debug.print("{d} ", .{c});
            cur2 = f.focusStep(c, true);
            if (cur2 != null and cur2.? == 1) break;
        }
        std.debug.print("\n", .{});
        try std.testing.expectEqual(@as(?u64, 2), f.focusStep(1, true));
        try std.testing.expectEqual(@as(?u64, x_key), f.focusStep(2, true));
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(x_key, true));
        // Back from 3 lands on the unkeyed control: it sits between 2 and 3
        // in document order now that it has a derived identity.
        try std.testing.expectEqual(@as(?u64, x_key), f.focusStep(3, false));
    }

    // Nothing focusable at all: Tab is not ours, so the caller gets null and
    // can hand the key to the app.
    rt.state.no_focus = true;
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?u64, null), f.focusStep(null, true));
    }
}

const FlexMsg = enum { fixed, filler };

fn flexView(_: *u8, ui: *Ui(FlexMsg)) *Element(FlexMsg) {
    const fixed = ui.button(.{ .label = "fixed", .msg = .fixed, .key = 1, .width = 100 });
    const filler = ui.button(.{ .label = "fill", .msg = .filler, .key = 2 });
    filler.grow = true;
    const row = ui.row(.{ .children = &.{ fixed, filler } });
    row.width = 300;
    return row;
}

fn flexUpdate(m: *u8, msg: FlexMsg) Action(FlexMsg) {
    _ = m;
    _ = msg;
    return .{};
}

fn rectOfKey(f: anytype, k: u64) Rect {
    for (f.hits) |h| {
        if (h.key) |hk| {
            if (hk == k) return h.rect;
        }
    }
    return .{ .x = -1, .y = -1, .w = -1, .h = -1 };
}

const StackMsg = enum { under, over };
const StackState = struct {};

fn stackUpdate(m: *StackState, msg: StackMsg) Action(StackMsg) {
    _ = m;
    _ = msg;
    return .{};
}

fn stackView(_: *StackState, ui: *Ui(StackMsg)) *Element(StackMsg) {
    // A 100x40 control with a 60x20 one landed on its top-left corner: the
    // arrangement a dropdown over a trigger makes.
    const under = ui.button(.{ .label = "under", .msg = .under, .key = 1, .width = 100, .height = 40 });
    const over = ui.button(.{ .label = "over", .msg = .over, .key = 2, .width = 60, .height = 20 });
    return ui.stack(.{ .children = &.{ under, over } });
}

test "overlapping children: the later one takes the pointer and the one under it does not" {
    const gpa = std.testing.allocator;
    var rt = Runtime(StackState, StackMsg).init(gpa, .{}, stackUpdate, stackView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();

    // The two boxes genuinely overlap -- the origin is shared, not stacked.
    const a = rectOfKey(f, 1);
    const b = rectOfKey(f, 2);
    try std.testing.expectApproxEqAbs(a.x, b.x, 0.01);
    try std.testing.expectApproxEqAbs(a.y, b.y, 0.01);

    // Where they overlap the TOP one answers, and it is the later child.
    try std.testing.expectEqual(StackMsg.over, f.hitTest(.{ 10, 10 }).?);
    // Past its edge the one underneath still answers: overlap must not make
    // the lower child unreachable everywhere, only where it is covered.
    try std.testing.expectEqual(StackMsg.under, f.hitTest(.{ 80, 30 }).?);
}

test "a stack costs no flow space, so a popup can hang outside its trigger" {
    const gpa = std.testing.allocator;
    var ui = Ui(StackMsg).init(gpa);
    defer ui.deinit();

    const popup = ui.button(.{ .label = "menu", .msg = .over, .key = 2, .width = 60, .height = 20 });
    const layer = ui.stack(.{ .children = &.{popup}, .height = 0 });
    const r = nominalRenderer();

    // Zero height means the column around it does not reserve room, which is
    // what lets the child paint over the content below instead of pushing it.
    try std.testing.expectApproxEqAbs(@as(f32, 0), layer.measure(r, 300).h, 0.01);
    // ...while the child itself is still 20 tall and still measurable.
    try std.testing.expectApproxEqAbs(@as(f32, 20), popup.measure(r, 300).h, 0.01);

    // A displacement keeps the child inside the stack's box...
    popup.offset = .{ 70, 40 };
    try std.testing.expectApproxEqAbs(@as(f32, 130), layer.measure(r, 300).w, 0.01);
    // Vertically the explicit 0 WINS over the child, and that override is the
    // overlay idiom rather than an accident: a stack that grew back to its
    // child's height would reserve the room it exists to avoid.
    try std.testing.expectApproxEqAbs(@as(f32, 0), layer.measure(r, 300).h, 0.01);
    // ...and a negative one does not shrink the box below zero.
    popup.offset = .{ -200, -200 };
    const neg = layer.measure(r, 300);
    try std.testing.expect(neg.w >= 0 and neg.h >= 0);
}

/// The y of the first text prim carrying exactly `bytes`. Text has no rect of its own, so a
/// baseline test has to read the glyph origin itself.
fn textYOf(f: anytype, bytes: []const u8) f32 {
    for (f.prims) |p| switch (p) {
        .text => |t| if (std.mem.eql(u8, t.bytes, bytes)) return t.y,
        else => {},
    };
    return -999;
}

const BaseMsg = enum { noop };
const BaseState = struct { mode: RowAlign = .baseline };

fn baseUpdate(m: *BaseState, msg: BaseMsg) Action(BaseMsg) {
    _ = m;
    _ = msg;
    return .{};
}

fn baseView(s: *BaseState, ui: *Ui(BaseMsg)) *Element(BaseMsg) {
    // A tall button and a loose caption: the button keeps its 60px box, the
    // caption is only as tall as its glyphs. Centring would put the caption's
    // MIDDLE on the button's middle; a baseline row puts the two lines of type
    // on one line, which is the thing a reader actually sees.
    const tall = ui.button(.{ .label = "tall", .msg = .noop, .key = 1, .height = 60 });
    const caption = ui.text(.{ .label = "caption", .size = 16 });
    const row = ui.row(.{ .children = &.{ tall, caption } });
    row.row_align = s.mode;
    return row;
}

test "a baseline row lines up the type, not the boxes" {
    const gpa = std.testing.allocator;
    var rt = Runtime(BaseState, BaseMsg).init(gpa, .{}, baseUpdate, baseView);
    defer rt.deinit();

    {
        var f = try rt.frame(.{ .w = 300, .h = 80 }, nominalRenderer());
        defer f.deinit();
        // Both are 16px type, so equal baselines mean equal glyph origins.
        try std.testing.expectApproxEqAbs(textYOf(f, "tall"), textYOf(f, "caption"), 0.5);
        // And the caption is NOT stretched to the button's box: its own height
        // is what it was measured at, which is the difference from `stretch`.
        const cap = rectOfKey(f, 1);
        try std.testing.expectApproxEqAbs(@as(f32, 60), cap.h, 0.5);
    }

    // The same frame under `start` does not line the type up, which is what
    // makes the assertion above worth having: it is comparing two things that
    // can disagree.
    rt.state.mode = .start;
    {
        var f = try rt.frame(.{ .w = 300, .h = 80 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expect(@abs(textYOf(f, "tall") - textYOf(f, "caption")) > 0.5);
    }
}

const MarginMsg = enum { a, b };
const MarginState = struct { alignment: RowAlign = .stretch, column: bool = false };

fn marginUpdate(m: *MarginState, msg: MarginMsg) Action(MarginMsg) {
    _ = m;
    _ = msg;
    return .{};
}

fn marginView(s: *MarginState, ui: *Ui(MarginMsg)) *Element(MarginMsg) {
    const a = ui.button(.{ .label = "a", .msg = .a, .key = 1, .width = 100, .height = 20 });
    // Uneven on purpose: a symmetric test passes whether or not the sides are
    // distinguished, which is the whole reason there are four fields.
    a.margin_left = 5;
    a.margin_right = 15;
    a.margin_top = 10;
    a.margin_bottom = 4;
    const b = ui.button(.{ .label = "b", .msg = .b, .key = 2, .width = 100, .height = 20 });
    if (s.column) return ui.column(.{ .children = &.{ a, b } });
    const row = ui.row(.{ .children = &.{ a, b } });
    row.row_align = s.alignment;
    return row;
}

test "a row spends the main-axis margins around the child it belongs to" {
    const gpa = std.testing.allocator;
    var rt = Runtime(MarginState, MarginMsg).init(gpa, .{}, marginUpdate, marginView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
    defer f.deinit();

    const a = rectOfKey(f, 1);
    const b = rectOfKey(f, 2);
    // Left margin offsets the child; the right one is space after it, so the
    // next child starts past BOTH the child and its right margin.
    try std.testing.expectApproxEqAbs(@as(f32, 5), a.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), a.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 120), b.x, 0.5);
}

test "a row's cross-axis margins shrink the slot the child is aligned in" {
    const gpa = std.testing.allocator;
    var rt = Runtime(MarginState, MarginMsg).init(gpa, .{}, marginUpdate, marginView);
    defer rt.deinit();

    // Stretch fills what the margins leave, and starts below the top one. A
    // margin is space the child does NOT get, so it cannot be overridden by
    // the alignment -- the two compose.
    {
        var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 10), rectOfKey(f, 1).y, 0.5);
        try std.testing.expectApproxEqAbs(@as(f32, 46), rectOfKey(f, 1).h, 0.5);
        // The un-margined neighbour still fills the whole row, which is what
        // makes the 46 above a margin effect and not the row being short.
        try std.testing.expectApproxEqAbs(@as(f32, 0), rectOfKey(f, 2).y, 0.5);
        try std.testing.expectApproxEqAbs(@as(f32, 60), rectOfKey(f, 2).h, 0.5);
    }
    // Center: the child keeps its own height and centres INSIDE the reduced
    // slot, so the margins are still respected rather than being centred away.
    rt.state.alignment = .center;
    {
        var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 20), rectOfKey(f, 1).h, 0.5);
        try std.testing.expectApproxEqAbs(@as(f32, 23), rectOfKey(f, 1).y, 0.5);
    }
}

test "a column spends the margins on the other axis, and its cross-axis margins shrink width" {
    const gpa = std.testing.allocator;
    var rt = Runtime(MarginState, MarginMsg).init(gpa, .{}, marginUpdate, marginView);
    defer rt.deinit();
    rt.state.column = true;

    var f = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer f.deinit();

    const a = rectOfKey(f, 1);
    const b = rectOfKey(f, 2);
    // Top margin below nothing, so it is the child's y; the bottom margin plus
    // the gap pushes the next child down.
    try std.testing.expectApproxEqAbs(@as(f32, 10), a.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 20), a.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 34), b.y, 0.5);
    // Same four numbers, the other pair of sides.
    try std.testing.expectApproxEqAbs(@as(f32, 5), a.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 80), a.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), b.w, 0.5);
}

test "a grow child takes the leftover width and the others keep theirs" {
    const gpa = std.testing.allocator;
    var rt = Runtime(u8, FlexMsg).init(gpa, 0, flexUpdate, flexView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 400, .h = 120 }, nominalRenderer());
    defer f.deinit();

    const fixed = rectOfKey(f, 1);
    const filler = rectOfKey(f, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 100), fixed.w, 0.5);
    // 300 of row, 100 taken by the fixed child, no gap: the rest is the share.
    try std.testing.expectApproxEqAbs(@as(f32, 200), filler.w, 0.5);
    // And they do not overlap: the filler starts where the fixed one ends.
    try std.testing.expectApproxEqAbs(fixed.x + fixed.w, filler.x, 0.5);
}

const AlignMsg = enum { tall, short };
const AlignState = struct { align_mode: RowAlign = .stretch };

fn alignUpdate(m: *AlignState, msg: AlignMsg) Action(AlignMsg) {
    _ = m;
    _ = msg;
    return .{};
}

fn alignView(s: *AlignState, ui: *Ui(AlignMsg)) *Element(AlignMsg) {
    const tall = ui.button(.{ .label = "tall", .msg = .tall, .key = 1, .height = 60 });
    const short = ui.button(.{ .label = "short", .msg = .short, .key = 2, .height = 20 });
    const row = ui.row(.{ .children = &.{ tall, short } });
    row.row_align = s.align_mode;
    return row;
}

test "a row places a short child according to row_align" {
    const gpa = std.testing.allocator;
    var rt = Runtime(AlignState, AlignMsg).init(gpa, .{}, alignUpdate, alignView);
    defer rt.deinit();

    // Stretch is the default, so this is the old behaviour: the short child is
    // given the full row height whatever it asked for.
    {
        var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 60), rectOfKey(f, 2).h, 0.5);
        try std.testing.expectApproxEqAbs(rectOfKey(f, 1).y, rectOfKey(f, 2).y, 0.5);
    }
    // Center: own height, sitting in the middle of the taller neighbour.
    rt.state.align_mode = .center;
    {
        var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 20), rectOfKey(f, 2).h, 0.5);
        try std.testing.expectApproxEqAbs(rectOfKey(f, 1).y + 20, rectOfKey(f, 2).y, 0.5);
    }
    // Start: own height, top edge level with the neighbour.
    rt.state.align_mode = .start;
    {
        var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectApproxEqAbs(@as(f32, 20), rectOfKey(f, 2).h, 0.5);
        try std.testing.expectApproxEqAbs(rectOfKey(f, 1).y, rectOfKey(f, 2).y, 0.5);
    }
}

test "a thumb exists only when there is overflow, and claims where it paints" {
    const gpa = std.testing.allocator;
    const ThMsg = enum { tap };
    const ThState = struct { fits: bool = false };

    const H = struct {
        fn upd(s: *ThState, m: ThMsg) Action(ThMsg) {
            _ = s;
            _ = m;
            return .{};
        }
        fn view(s: *ThState, ui: *Ui(ThMsg)) *Element(ThMsg) {
            var kids: [10]*Element(ThMsg) = undefined;
            for (&kids, 0..) |*k, i| {
                k.* = ui.rect(.{ .width = 80, .height = 20, .key = 100 + i });
            }
            const col = ui.column(.{ .key = 7, .height = if (s.fits) 300 else 100, .children = &kids });
            return ui.column(.{ .children = &.{col} });
        }
    };

    var st: ThState = .{};
    var rt = Runtime(ThState, ThMsg).init(gpa, st, H.upd, H.view);
    defer rt.deinit();

    // 200 of content in a 100px view: the thumb is half the track, pinned to
    // the top at offset zero, and its grab area is wider than the 6px it
    // draws -- a 6px target is not draggable with a finger or a trackpad.
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        var thumb: ?Hit(ThMsg) = null;
        for (f.hits) |h| {
            if (h.drag != null) thumb = h;
        }
        const t = thumb orelse return error.NoThumb;
        try std.testing.expectEqual(@as(f32, 186), t.rect.x); // 200 - grab
        try std.testing.expectEqual(@as(f32, 14), t.rect.w);
        try std.testing.expectEqual(@as(f32, 0), t.rect.y);
        try std.testing.expectEqual(@as(f32, 50), t.rect.h);
        // The thumb carries the viewport's identity for the drag, but NOT as a
        // `key`: a second region with key 7 would trip the duplicate-key guard
        // and would let `Press.rebind` hand the claim to the content region.
        try std.testing.expectEqual(@as(?u64, null), t.key);
        try std.testing.expectEqual(vpKey(), t.drag.?.thumb.key);
        // No message: a thumb produces an offset, not an event.
        try std.testing.expectEqual(@as(?ThMsg, null), t.msg);
    }

    // Content that fits: nothing to scroll, so no thumb and nothing to grab.
    st.fits = true;
    rt.state = st;
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        for (f.hits) |h| {
            if (h.drag != null) return error.ThumbWithoutOverflow;
        }
    }
}

test "a keyed scroll viewport is one region, so it cannot collide with itself" {
    const VM = enum { press };
    const VS = struct {};
    const VH = struct {
        fn upd(_: *VS, _: VM) Action(VM) {
            return .{};
        }
        fn view(_: *VS, ui: *Ui(VM)) *Element(VM) {
            var kids: [12]*Element(VM) = undefined;
            for (&kids, 0..) |*k, i| {
                k.* = ui.rect(.{ .width = 80, .height = 20, .key = 200 + i });
            }
            const vp = ui.column(.{ .key = 7, .height = 100, .children = &kids, .on_press = .press });
            // Focusable is a plain field: it exists for the Tab order, which no
            // builder needs to spell out.
            vp.focusable = true;
            return ui.column(.{ .children = &.{vp} });
        }
    };

    const gpa = std.testing.allocator;
    var rt = Runtime(VS, VM).init(gpa, .{}, VH.upd, VH.view);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
    defer f.deinit();

    // The old behaviour recorded the generic region AND the viewport region
    // under one key, and the duplicate-key guard reported the app for using
    // scrolling the way it is documented.
    var seen: usize = 0;
    var vp: ?Hit(VM) = null;
    for (f.hits) |h| {
        if (h.key == 7) {
            seen += 1;
            vp = h;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
    const v = vp orelse return error.NoViewportRegion;
    // One region still has to do every job the two did between them.
    try std.testing.expectEqual(@as(?VM, .press), v.msg);
    try std.testing.expect(v.focusable);
    try std.testing.expect(v.active);
    try std.testing.expect(v.scroll != null);
    try std.testing.expect(!rt.ui.failed);

    // And the offset is readable from both sides of a frame.
    try std.testing.expectEqual(@as(f32, 0), rt.ui.scrollAt(7));
    rt.scrollBy(7, 15);
    try std.testing.expectEqual(@as(f32, 15), rt.scrollOffset(7));
    var f2 = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
    defer f2.deinit();
    try std.testing.expectEqual(@as(f32, 15), rt.ui.scrollAt(7));
}

test "a primitive that cannot be recorded is reported, not silently dropped" {
    const gpa = std.testing.allocator;
    var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var col: Collector(u8) = .{ .gpa = fa.allocator(), .metrics = nominalRenderer() };
    col.renderer().quad(
        .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .solid = .{ .r = 1, .g = 2, .b = 3, .a = 255 } },
        Rect.unbounded,
    );
    try std.testing.expect(col.failed);
    try std.testing.expectEqual(@as(usize, 0), col.prims.items.len);

    // The flag has to mean something: the same call with memory to spend
    // records the primitive and reports nothing.
    var ok: Collector(u8) = .{ .gpa = gpa, .metrics = nominalRenderer() };
    defer ok.prims.deinit(gpa);
    ok.renderer().quad(
        .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .solid = .{ .r = 1, .g = 2, .b = 3, .a = 255 } },
        Rect.unbounded,
    );
    try std.testing.expect(!ok.failed);
    try std.testing.expectEqual(@as(usize, 1), ok.prims.items.len);
}

test "a label wider than its element is elided and stays inside it" {
    const EM = enum { nop };
    const ES = struct { wide: bool = false };
    const EH = struct {
        fn upd(_: *ES, _: EM) Action(EM) {
            return .{};
        }
        fn view(s: *ES, ui: *Ui(EM)) *Element(EM) {
            const t = ui.text(.{ .label = "a fairly long label", .size = 10 });
            t.width = if (s.wide) 200 else 40;
            return ui.column(.{ .children = &.{t} });
        }
    };

    const gpa = std.testing.allocator;
    var rt = Runtime(ES, EM).init(gpa, .{}, EH.upd, EH.view);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
    defer f.deinit();
    var prims: usize = 0;
    var last: ?[]const u8 = null;
    var box: ?Rect = null;
    for (f.prims) |p| switch (p) {
        .text => |t| {
            prims += 1;
            last = t.bytes;
            // Contained: every glyph is clipped by the element's own box, and
            // two call sites that disagreed about that box would show up here.
            if (box) |b| {
                try std.testing.expectEqual(b.x, t.clip.x);
                try std.testing.expectEqual(b.w, t.clip.w);
            } else box = t.clip;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), prims);
    try std.testing.expectEqualStrings(ellipsis, last.?);

    // Wide enough, so nothing is dropped and nothing is appended.
    rt.state.wide = true;
    var f2 = try rt.frame(.{ .w = 300, .h = 60 }, nominalRenderer());
    defer f2.deinit();
    var wide_prims: usize = 0;
    for (f2.prims) |p| switch (p) {
        .text => wide_prims += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), wide_prims);
}

test "a stepped click nudges one step toward the pointer, it does not snap" {
    var v: f32 = 50;
    const d = SliderDrag{
        .key = 1,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 10 },
        .value = &v,
        .min = 0,
        .max = 100,
        .step = 5,
        .orientation = .horizontal,
    };
    // Click far along the track: one step, not eighty percent of the range.
    try std.testing.expectEqual(@as(f32, 55), sliderStepToward(d, 50, .{ 80, 5 }));
    try std.testing.expectEqual(@as(f32, 45), sliderStepToward(d, 50, .{ 20, 5 }));
    // A DRAG is not a click: it tracks the pointer, quantised as it goes.
    try std.testing.expectEqual(@as(f32, 80), sliderValueAt(d, .{ 80, 5 }));
    // Already nearest the pointer: a click changes nothing.
    try std.testing.expectEqual(@as(f32, 55), sliderStepToward(d, 55, .{ 55, 5 }));
}

test "a stepped slider lands on the grid, never between steps" {
    var v: f32 = 50;
    const d = SliderDrag{
        .key = 1,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 10 },
        .value = &v,
        .min = 0,
        .max = 100,
        .step = 40,
        .orientation = .horizontal,
    };
    // The pointer is at 60 and the grid is {0, 40, 80}: 60 is halfway, so the
    // target is 80 and the step from 50 is capped there. The value must land ON
    // a step, so "stop exactly where I clicked" is not available to a stepped
    // control -- that is what `step = null` is for.
    try std.testing.expectEqual(@as(f32, 80), sliderStepToward(d, 50, .{ 60, 5 }));
    // An off-grid current value still moves onto the grid rather than staying
    // between steps, which is the one visible consequence of allowing `step`
    // without enforcing it.
    try std.testing.expectEqual(@as(f32, 40), sliderStepToward(d, 50, .{ 45, 5 }));
}

test "a continuous slider goes exactly where it was clicked" {
    var v: f32 = 0;
    const d = SliderDrag{
        .key = 1,
        .rect = .{ .x = 10, .y = 0, .w = 100, .h = 10 },
        .value = &v,
        .min = 0,
        .max = 1,
        .step = null,
        .orientation = .horizontal,
    };
    try std.testing.expectEqual(@as(f32, 0.5), sliderValueAt(d, .{ 60, 5 }));
    // And a click is the same mapping, since there is no grid to nudge along.
    try std.testing.expectEqual(@as(f32, 0.5), sliderStepToward(d, 0, .{ 60, 5 }));
}

test "a vertical slider is loudest at the top" {
    var v: f32 = 0;
    const d = SliderDrag{
        .key = 1,
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 100 },
        .value = &v,
        .min = 0,
        .max = 100,
        .step = null,
        .orientation = .vertical,
    };
    try std.testing.expectEqual(@as(f32, 100), sliderValueAt(d, .{ 5, 0 }));
    try std.testing.expectEqual(@as(f32, 0), sliderValueAt(d, .{ 5, 100 }));
    // Outside the track clamps instead of running off the end.
    try std.testing.expectEqual(@as(f32, 100), sliderValueAt(d, .{ 5, -50 }));
}

const ScopeMsg = enum { a, b, c };
const ScopeState = struct { open: bool = true };

/// A dialog (keys 10, 11) over a page that has one control of its own (20).
fn scopeView(s: *ScopeState, ui: *Ui(ScopeMsg)) *Element(ScopeMsg) {
    const behind = ui.button(.{ .label = "behind", .msg = .a, .key = 20 });
    behind.focusable = true;
    const one = ui.button(.{ .label = "one", .msg = .b, .key = 10 });
    one.focusable = true;
    const two = ui.button(.{ .label = "two", .msg = .b, .key = 11 });
    two.focusable = true;
    const dlg = ui.column(.{ .children = &.{ one, two } });
    dlg.key = 99;
    dlg.focus_scope = s.open;
    return ui.column(.{ .children = &.{ behind, dlg } });
}

fn scopeUpdate(_: *ScopeState, _: ScopeMsg) Action(ScopeMsg) {
    return .{};
}

test "focus does not leave an open scope" {
    const gpa = std.testing.allocator;
    var rt = Runtime(ScopeState, ScopeMsg).init(gpa, .{}, scopeUpdate, scopeView);
    defer rt.deinit();

    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        // The dialog's controls sit in the dialog's scope, the page control does
        // not. Without this, Tab walks the page behind an open dialog.
        try std.testing.expectEqual(@as(?u64, 99), f.scopeOf(10));
        try std.testing.expectEqual(@as(?u64, 99), f.scopeOf(11));
        try std.testing.expectEqual(@as(?u64, null), f.scopeOf(20));
        // Cycling inside the dialog, never reaching the control behind it.
        try std.testing.expectEqual(@as(?u64, 11), f.focusStep(10, true));
        try std.testing.expectEqual(@as(?u64, 10), f.focusStep(11, true));
        try std.testing.expectEqual(@as(?u64, 11), f.focusStep(10, false));
    }

    // Closed, the scope is gone and Tab crosses the whole page again.
    rt.state.open = false;
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(?u64, null), f.scopeOf(10));
        try std.testing.expectEqual(@as(?u64, 11), f.focusStep(10, true));
        try std.testing.expectEqual(@as(?u64, 20), f.focusStep(11, true));
    }
}

/// A dialog (scope 99) holding a panel that declares a scope of its own (88).
fn nestedScopeView(s: *ScopeState, ui: *Ui(ScopeMsg)) *Element(ScopeMsg) {
    const inner = ui.button(.{ .label = "inner", .msg = .c, .key = 12 });
    inner.focusable = true;
    const panel = ui.column(.{ .children = &.{inner} });
    panel.key = 88;
    panel.focus_scope = true;

    const outer = ui.button(.{ .label = "outer", .msg = .b, .key = 10 });
    outer.focusable = true;
    const dlg = ui.column(.{ .children = &.{ outer, panel } });
    dlg.key = 99;
    dlg.focus_scope = s.open;
    return dlg;
}

test "a nested scope wins over the one around it" {
    const gpa = std.testing.allocator;
    var rt = Runtime(ScopeState, ScopeMsg).init(gpa, .{}, scopeUpdate, nestedScopeView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
    defer f.deinit();
    // `scopeOf` promises "the innermost element that declared focus_scope".
    // Stamping happens on the way OUT, so the outer element's defer runs last
    // and -- without a guard -- rewrites every hit its subtree produced,
    // including the ones an inner scope had already claimed.
    try std.testing.expectEqual(@as(?u64, 99), f.scopeOf(10));
    try std.testing.expectEqual(@as(?u64, 88), f.scopeOf(12));
}

const DisMsg = enum { moved, toggled };
const DisState = struct {
    v: f32 = 0.5,
    v_active: ?u16 = null,
    enabled: bool = true,
    opened: bool = false,
    hits: u32 = 0,
};

fn disUpdate(s: *DisState, m: DisMsg) Action(DisMsg) {
    switch (m) {
        .moved, .toggled => s.hits += 1,
    }
    return .{};
}

var dis_opts = [_]Choice(DisMsg){
    .{ .label = "a", .msg = .toggled },
    .{ .label = "b", .msg = .toggled },
};

/// A disabled slider and a disabled select: both must stay inert, which for a widget means
/// "cannot be dragged and cannot be opened".
fn disView(s: *DisState, ui: *Ui(DisMsg)) *Element(DisMsg) {
    const track = ui.rect(.{ .width = 100, .height = 20 });
    track.key = 70;
    track.focusable = true;
    track.disabled = !s.enabled;
    track.widget = ui.payload(.{ .slider = .{
        .value = &s.v,
        .min = 0,
        .max = 1,
        .step = null,
        .orientation = .horizontal,
        .msg = .moved,
    } });

    const field = ui.button(.{ .label = "pick", .msg = .toggled, .key = 71 });
    field.focusable = true;
    field.disabled = !s.enabled;
    field.widget = ui.payload(.{ .select = .{
        .open = s.opened,
        .selected = 0,
        .active = &s.v_active,
        .options = &dis_opts,
        .msg = .toggled,
    } });

    return ui.column(.{ .children = &.{ track, field } });
}

test "a disabled widget is inert, not merely quiet" {
    const gpa = std.testing.allocator;
    var st = DisState{};
    st.v_active = null;
    var rt = Runtime(DisState, DisMsg).init(gpa, .{}, disUpdate, disView);
    defer rt.deinit();
    rt.state = st;
    rt.state.enabled = false;

    var f = try rt.frame(.{ .w = 200, .h = 200 }, nominalRenderer());
    defer f.deinit();

    // The region is still RECORDED -- vanishing would let a click fall through
    // to whatever sits behind it -- but `hit` refuses to claim it, which is
    // what stops the runtime starting a slider drag on it.
    const mid: [2]f32 = .{ 50, 10 };
    try std.testing.expect(f.hit(mid) == null);
    const field_mid: [2]f32 = .{ 20, 32 };
    try std.testing.expect(f.hit(field_mid) == null);

    // Enabled, the same points DO claim, and the slider's claim carries a
    // drag. Without this half a view that recorded nothing at all would pass.
    rt.state.enabled = true;
    var f2 = try rt.frame(.{ .w = 200, .h = 200 }, nominalRenderer());
    defer f2.deinit();
    const hit = f2.hit(mid) orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit.drag != null);
    try std.testing.expect(f2.hit(field_mid) != null);
}

const RoveMsg = enum { pick };
const RoveState = struct {};

/// A roving control (key 30) with three rows (40, 41, 42), then a control that follows it
/// (50).
fn roveView(_: *RoveState, ui: *Ui(RoveMsg)) *Element(RoveMsg) {
    const owner = ui.button(.{ .label = "list", .msg = .pick, .key = 30 });
    owner.focusable = true;
    var kids: [5]*Element(RoveMsg) = undefined;
    kids[0] = owner;
    var i: u16 = 0;
    while (i < 3) : (i += 1) {
        const r = ui.button(.{ .label = "row", .msg = .pick, .key = 40 + i });
        // Rows ARE focusable -- Enter has to be routable to one of them. It is
        // `roving` that keeps them out of the Tab cycle, not inertness, so a
        // test with inert rows would pass with the roving rule deleted.
        r.focusable = true;
        r.roving = 30;
        r.roving_index = i;
        kids[1 + i] = r;
    }
    const after = ui.button(.{ .label = "after", .msg = .pick, .key = 50 });
    after.focusable = true;
    kids[4] = after;
    return ui.column(.{ .children = &kids });
}

fn roveUpdate(_: *RoveState, _: RoveMsg) Action(RoveMsg) {
    return .{};
}

test "a roving control is one tab stop, not one per row" {
    const gpa = std.testing.allocator;
    var rt = Runtime(RoveState, RoveMsg).init(gpa, .{}, roveUpdate, roveView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
    defer f.deinit();

    // Tab lands on the control and then leaves: no row is a stop of its own.
    try std.testing.expectEqual(@as(?u64, 30), f.focusStep(null, true));
    try std.testing.expectEqual(@as(?u64, 50), f.focusStep(30, true));
    try std.testing.expectEqual(@as(?u64, 30), f.focusStep(50, true));
    try std.testing.expectEqual(@as(?u64, 30), f.focusStep(50, false));
}

test "a roving cursor moves between rows and stops at the ends" {
    const gpa = std.testing.allocator;
    var rt = Runtime(RoveState, RoveMsg).init(gpa, .{}, roveUpdate, roveView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
    defer f.deinit();

    try std.testing.expectEqual(@as(u16, 1), f.rovingStep(30, 0, 1).?.index);
    try std.testing.expectEqual(@as(u64, 41), f.rovingStep(30, 0, 1).?.key);
    // Walking off the end stops on the last row instead of wrapping, because
    // the far end of a long list is usually offscreen and a teleport reads as
    // a jump to nowhere.
    try std.testing.expectEqual(@as(u16, 2), f.rovingStep(30, 2, 1).?.index);
    try std.testing.expectEqual(@as(u16, 0), f.rovingStep(30, 0, -1).?.index);
    // A control with no rows has nothing to step through.
    try std.testing.expectEqual(@as(?Frame(RoveMsg).Roamer, null), f.rovingStep(50, 0, 1));
}

test "a centred popup straddles its anchor instead of hanging off it" {
    const anchor = Rect{ .x = 100, .y = 100, .w = 120, .h = 24 };
    const view = Size{ .w = 400, .h = 300 };
    const lay = popupLayout(anchor, 120, 4, null, view, .centred, popup_row_h);
    try std.testing.expectEqual(@as(usize, 4), lay.count);
    // Centred on the anchor's middle row: half the box above, half below.
    const want_y = 100 + 12 - (4 * popup_row_h) / 2;
    try std.testing.expectApproxEqAbs(want_y, lay.rect.y, 0.01);
    try std.testing.expectApproxEqAbs(100.0, lay.rect.x, 0.01);
}

test "a popup box keeps its height while the active row moves" {
    const anchor = Rect{ .x = 10, .y = 200, .w = 100, .h = 20 };
    const view = Size{ .w = 400, .h = 400 };
    var prev: ?Rect = null;
    var row: usize = 0;
    while (row < 20) : (row += 1) {
        const lay = popupLayout(anchor, 100, 20, row, view, .centred, popup_row_h);
        // A LITERAL, not the constant: asserting `count == popup_max_rows`
        // passes for any cap at all, including an even one, so it proves
        // nothing. The cap has to be stated here for the check to bite.
        try std.testing.expectEqual(@as(usize, 5), lay.count);
        try std.testing.expect(popup_max_rows % 2 == 1);
        if (prev) |p| {
            // The box does not move with the highlight. Re-centring it per row
            // is the bug this asserts against: the whole popup would jump on
            // every arrow press.
            try std.testing.expectApproxEqAbs(p.y, lay.rect.y, 0.01);
            try std.testing.expectApproxEqAbs(p.h, lay.rect.h, 0.01);
        }
        // Only the window slides, and it always holds the active row.
        try std.testing.expect(lay.first <= row and row < lay.first + lay.count);
        prev = lay.rect;
    }
}

test "a menu drops below and flips above when there is no room" {
    const view = Size{ .w = 400, .h = 300 };
    const high = Rect{ .x = 50, .y = 60, .w = 90, .h = 24 };
    const lay = popupLayout(high, 90, 3, null, view, .below, popup_row_h);
    try std.testing.expectApproxEqAbs(84.0, lay.rect.y, 0.01); // below the trigger
    try std.testing.expectApproxEqAbs(50.0, lay.rect.x, 0.01); // left edges aligned

    const low = Rect{ .x = 50, .y = 260, .w = 90, .h = 24 };
    const flip = popupLayout(low, 90, 3, null, view, .below, popup_row_h);
    // 284 + 78 would leave the screen, so it opens upward instead.
    try std.testing.expectApproxEqAbs(260.0 - 78.0, flip.rect.y, 0.01);
}

test "a menu anchored off the left edge is pulled back on screen" {
    const view = Size{ .w = 400, .h = 300 };
    const anchor = Rect{ .x = -50, .y = 40, .w = 100, .h = 24 };
    const lay = popupLayout(anchor, 100, 3, null, view, .below, popup_row_h);
    try std.testing.expectApproxEqAbs(0.0, lay.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(64.0, lay.rect.y, 0.01);
}

test "an arrow asks the frame where a roving cursor goes" {
    const gpa = std.testing.allocator;
    var rt = Runtime(RoveState, RoveMsg).init(gpa, .{}, roveUpdate, roveView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
    defer f.deinit();

    // The caller has a focused key and a direction; the owner and row index
    // stay inside the frame.
    try std.testing.expectEqual(@as(u64, 41), f.rovingMove(40, 1).?.key);
    try std.testing.expectEqual(@as(u64, 40), f.rovingMove(41, -1).?.key);
    // Row 0 back one row stays on row 0 rather than wrapping.
    try std.testing.expectEqual(@as(u64, 40), f.rovingMove(40, -1).?.key);

    // The control ITSELF: an arrow steps into its rows. This is the state
    // Tab always produces, since `focusStep` skips every row -- asserting
    // null here (as this test used to) made the rows unreachable by keyboard.
    try std.testing.expectEqual(@as(u64, 40), f.rovingMove(30, 1).?.key);
    try std.testing.expectEqual(@as(u64, 42), f.rovingMove(30, -1).?.key);

    // A control that owns no rows, and no focus at all: the key must reach
    // the app instead. This is the assertion that stops every arrow press in
    // the window being swallowed.
    try std.testing.expect(f.rovingMove(50, 1) == null);
    try std.testing.expect(f.rovingMove(null, 1) == null);
}

test "finished workers are reaped instead of accumulating for the session" {
    const H = struct {
        fn seven(ctx: *const anyopaque) ?u32 {
            _ = ctx;
            return 7;
        }
    };
    const box = [_]u8{0};
    const cmd = Cmd(u32){ .ctx = @ptrCast(&box), .run = H.seven };

    var ex = Executor(u32){ .gpa = std.testing.allocator };
    defer ex.deinit();

    for (0..8) |_| ex.submit(cmd);

    var guard: usize = 0;
    while (ex.busy() and guard < 20_000) : (guard += 1) std.Thread.yield() catch {};
    try std.testing.expect(!ex.busy());
    try std.testing.expectEqual(@as(usize, 0), ex.lostCommands());

    ex.reap();
    // Without the reap this is 8 -- one handle per command, kept until deinit,
    // which for a long session is an unbounded list of finished threads.
    try std.testing.expectEqual(@as(usize, 0), ex.handles.items.len);

    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(std.testing.allocator);
    try ex.drainInto(&got);
    try std.testing.expectEqual(@as(usize, 8), got.items.len);
}

test "a command still running does not stop finished ones being reaped" {
    const H = struct {
        var release: std.atomic.Value(bool) = .init(false);
        var quick_done: std.atomic.Value(usize) = .init(0);
        fn block(ctx: *const anyopaque) ?u32 {
            _ = ctx;
            // No iteration cap. This command must still be running when the
            // assertions below run, and a bounded loop let it finish on its
            // own under load -- which made the test fail for a reason that had
            // nothing to do with the reaping rule it exists to check.
            while (!release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            return 1;
        }
        fn quick(ctx: *const anyopaque) ?u32 {
            _ = ctx;
            _ = quick_done.fetchAdd(1, .acq_rel);
            return 2;
        }
    };
    H.release.store(false, .release);
    H.quick_done.store(0, .release);

    const box = [_]u8{0};
    var ex = Executor(u32){ .gpa = std.testing.allocator };
    defer ex.deinit();

    ex.submit(.{ .ctx = @ptrCast(&box), .run = H.block });
    for (0..8) |_| ex.submit(.{ .ctx = @ptrCast(&box), .run = H.quick });

    var guard: usize = 0;
    while (H.quick_done.load(.acquire) < 8 and guard < 400_000) : (guard += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 8), H.quick_done.load(.acquire));

    // The blocked command is still running, so the executor is busy: reaping
    // only when `outstanding == 0` would leave ALL NINE handles here. The
    // finished ones are joinable regardless, which is the whole point.
    try std.testing.expect(ex.busy());
    ex.reap();
    try std.testing.expectEqual(@as(usize, 1), ex.handles.items.len);

    H.release.store(true, .release);
    guard = 0;
    while (ex.busy() and guard < 400_000) : (guard += 1) std.Thread.yield() catch {};
    try std.testing.expect(!ex.busy());
    ex.reap();
    try std.testing.expectEqual(@as(usize, 0), ex.handles.items.len);
}

test "a result that cannot be queued is counted, not dropped in silence" {
    // `lost` exists because a command with no message is indistinguishable, from
    // the app's side, from one that is merely slow. A result that finished and
    // then failed to fit is the same situation and gets the same count -- the
    // alternative is a screen that waits forever with no way to tell why.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ex: Executor(u32) = .{ .gpa = failing.allocator() };
    defer ex.deinit();

    ex.queueLocked(7);
    try std.testing.expectEqual(@as(usize, 0), ex.done.items.len);
    try std.testing.expectEqual(@as(usize, 1), ex.lostCommands());
}

test "a burst of commands cannot grow threads without bound" {
    // The commands BLOCK until released, or the fast ones would finish before
    // the next submit and the cap would never bind -- the first version of this
    // test passed for exactly that reason and proved nothing.
    var ex: Executor(u32) = .{ .gpa = std.testing.allocator, .max_running = 2 };
    defer ex.deinit();

    const Gate = struct {
        ran: std.atomic.Value(usize) = .init(0),
        release: std.atomic.Value(bool) = .init(false),
    };
    var gate = Gate{};
    const H = struct {
        fn hold(ctx: *const anyopaque) ?u32 {
            const g: *Gate = @ptrCast(@alignCast(@constCast(ctx)));
            _ = g.ran.fetchAdd(1, .monotonic);
            while (!g.release.load(.acquire)) std.Thread.yield() catch {};
            return 1;
        }
    };
    // If any assertion below fails, `deinit` waits for `outstanding` to reach
    // zero and the blocked workers only stop when released -- so a failing
    // assert used to HANG the test binary instead of reporting. Release first.
    errdefer gate.release.store(true, .release);
    for (0..6) |_| ex.submit(.{ .ctx = @ptrCast(&gate), .run = H.hold });

    try std.testing.expectEqual(@as(usize, 2), ex.handles.items.len);
    ex.mutex.lock();
    const queued = ex.pending.items.len;
    ex.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 4), queued);

    // Releasing lets a worker take the next queued command before it exits, so
    // the queue drains with no extra threads and no `reap` in this loop.
    gate.release.store(true, .release);
    var guard: usize = 0;
    while (ex.busy() and guard < 400_000) : (guard += 1) std.Thread.yield() catch {};
    try std.testing.expect(!ex.busy());
    try std.testing.expectEqual(@as(usize, 6), gate.ran.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), ex.lostCommands());
    try std.testing.expectEqual(@as(usize, 2), ex.handles.items.len);

    ex.reap();
    try std.testing.expectEqual(@as(usize, 0), ex.handles.items.len);
}

const WgMsg = enum { moved, toggled, pick_a, pick_b };
const WgState = struct {
    v: f32 = 0.25,
    active: ?u16 = null,
    open: bool = false,
};

fn wgUpdate(s: *WgState, m: WgMsg) Action(WgMsg) {
    _ = s;
    _ = m;
    return .{};
}

const wg_options = [_]Choice(WgMsg){
    .{ .label = "alpha", .msg = .pick_a },
    .{ .label = "beta", .msg = .pick_b },
};

fn wgView(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    return ui.column(.{ .children = &.{
        ui.slider(.{ .key = 80, .value = &s.v, .msg = .moved }),
        ui.select(.{
            .key = 81,
            .open = s.open,
            .selected = 1,
            .active = &s.active,
            .options = &wg_options,
            .msg = .toggled,
        }),
        ui.menu(.{
            .key = 82,
            .label = "File",
            .open = false,
            .active = &s.active,
            .items = &wg_options,
            .toggle = .toggled,
        }),
    } });
}

fn wgControls(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    return ui.column(.{ .gap = 6, .children = &.{
        ui.control(.{ .key = 101, .label = "Remember", .checked = true, .msg = .toggled }),
        ui.control(.{ .key = 102, .label = "Small", .kind = .radio, .checked = false, .msg = .pick_a }),
        ui.control(.{ .key = 103, .label = "Enabled", .kind = .toggle, .checked = true, .msg = .moved }),
    } });
}

test "a control claims its whole row, and only the checked one is marked" {
    const gpa = std.testing.allocator;
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgControls);
    defer rt.deinit();

    const th = Theme{};
    var f = try rt.frame(.{ .w = 240, .h = 140 }, nominalRenderer());
    defer f.deinit();

    // The BOX is at the left edge; the label follows it. Both must resolve to
    // the control, because a 16px box is not a target anyone can hit reliably.
    const on_box = f.hit(.{ 6, 6 }).?;
    try std.testing.expectEqual(@as(?u64, 101), on_box.key);
    try std.testing.expectEqual(WgMsg.toggled, on_box.msg.?);
    try std.testing.expect(on_box.focusable);
    // Far right of the same row, past the end of the word.
    try std.testing.expectEqual(@as(?u64, 101), f.hit(.{ 200, 6 }).?.key);
    // And the row below is a different control, not the same region stretched.
    try std.testing.expectEqual(@as(?u64, 102), f.hit(.{ 6, 30 }).?.key);

    // One accent fill for the checked checkbox's box and one for the checked
    // switch's track; the unchecked radio contributes none, which is what
    // "checked is drawn from the Model" has to mean in pixels.
    try std.testing.expectEqual(@as(usize, 2), countSolidPrims(f.prims, th.accent));
}

fn wgToastOnly(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    return ui.column(.{ .children = &.{
        ui.toast(.{ .key = 91, .text = "Saved", .severity = .success, .ttl_ms = 1500, .msg = .toggled }),
    } });
}

test "a toast carries the severity and ttl the runtime expires it by, and a click dismisses it" {
    const gpa = std.testing.allocator;
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgToastOnly);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 220, .h = 120 }, nominalRenderer());
    defer f.deinit();

    // A click dismisses: the panel is pressable AND keyed, which is the same
    // hit region the runtime reads the countdown's rect from. A toast with no
    // region would never have its timer paused, and one with no key would never
    // be matched to a slot at all.
    const h = f.hit(.{ 10, 10 }).?;
    try std.testing.expectEqual(@as(?u64, 91), h.key);
    try std.testing.expectEqual(WgMsg.toggled, h.msg.?);
    // Not a Tab stop. A notification that steals focus interrupts whatever the
    // reader was doing, which is the opposite of what a notification is for.
    try std.testing.expect(!h.focusable);
    // Padded, so the panel is taller than the single line of text inside it.
    try std.testing.expect(h.rect.h >= 16);

    // By key, not off the hit: `hit` hands back a copy with the payload
    // stripped, which is what keeps a public Region from borrowing frame memory.
    const w = f.widgetAt(91) orelse return error.TestUnexpectedResult;
    switch (w.*) {
        .toast => |t| {
            try std.testing.expectEqual(Severity.success, t.severity);
            try std.testing.expectEqual(@as(u32, 1500), t.ttl_ms);
            try std.testing.expectEqual(WgMsg.toggled, t.msg);
        },
        else => return error.TestUnexpectedResult,
    }

    // The stripe reaches paint in the SUCCESS colour, not merely in "a" colour.
    // Success, warning and error are one line each in `severityColor`, so a
    // copy-paste that leaves two severities sharing a colour is likely, and it
    // would look like a working toast.
    const th = Theme{};
    try std.testing.expectEqual(@as(usize, 1), countSolidPrims(f.prims, th.success));
    try std.testing.expectEqual(@as(usize, 0), countSolidPrims(f.prims, th.warning));
    try std.testing.expectEqual(@as(usize, 0), countSolidPrims(f.prims, th.fail));
    // `info` is the accent, so a toast that ignores its severity entirely --
    // the other way to get this wrong -- is caught by the success count above
    // only while the default stays `info`.
    try std.testing.expectEqual(@as(usize, 0), countSolidPrims(f.prims, th.accent));
}

fn wgSliderOnly(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    // Inside a column, not as the root: the root is stretched to the canvas, so
    // a slider placed there claims the whole window and a point below the band
    // still hits it. Here the band is the only thing with a rect.
    return ui.column(.{ .children = &.{
        ui.slider(.{ .key = 80, .value = &s.v, .msg = .moved, .length = 100, .thickness = 6 }),
    } });
}

fn wgListOnly(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    return ui.column(.{ .children = &.{
        ui.list(.{
            .key = 90,
            .selected = 1,
            .rows = &.{
                .{ .label = "one", .msg = .pick_a },
                .{ .label = "two", .msg = .pick_b },
                .{ .label = "three" },
            },
        }),
    } });
}

fn wgTabsAt(s: *WgState, ui: *Ui(WgMsg), sel: u16) *Element(WgMsg) {
    _ = s;
    const a = ui.rect(.{ .width = 10, .height = 10, .style = .{ .bg = solid(Color.rgbHex(0x123456)) } });
    const b = ui.rect(.{ .width = 10, .height = 10, .style = .{ .bg = solid(Color.rgbHex(0x654321)) } });
    return ui.column(.{ .children = &.{
        ui.tabs(.{
            .key = 95,
            .selected = sel,
            .tabs = &.{
                .{ .label = "A", .msg = .pick_a, .children = &.{a} },
                .{ .label = "B", .msg = .pick_b, .children = &.{b} },
            },
        }),
    } });
}

fn wgTabsFirst(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    return wgTabsAt(s, ui, 0);
}

fn wgTabsSecond(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    return wgTabsAt(s, ui, 1);
}

fn wgTipView(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    const t = ui.text(.{ .label = "Save", .size = 16 });
    t.tooltip = "Save the document";
    return ui.column(.{ .children = &.{t} });
}

test "a tooltip waits for the delay, then paints above everything else" {
    const gpa = std.testing.allocator;
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgTipView);
    defer rt.deinit();
    rt.pointer.pos = .{ 10, 10 };

    // Pointer resting, but not yet long enough: nothing is drawn. The delay is
    // the whole difference between an explanation and a flicker.
    rt.hover_since = 0.2;
    var cold = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer cold.deinit();
    const base = cold.prims.len;

    // Same frame, pointer rested: a panel, an edge and one line of text, all of
    // it AFTER the tree so it sits on top rather than under the label it explains.
    rt.hover_since = 0.9;
    var warm = try rt.frame(.{ .w = 300, .h = 200 }, nominalRenderer());
    defer warm.deinit();
    try std.testing.expectEqual(base + 3, warm.prims.len);

    // The last three prims are the tip, in the order they must paint.
    try std.testing.expect(warm.prims[warm.prims.len - 1] == .text);
    try std.testing.expect(warm.prims[warm.prims.len - 2] == .quad);
    try std.testing.expect(warm.prims[warm.prims.len - 3] == .quad);
}

test "a list is one tab stop, and every row is a cursor stop including a label-only one" {
    const gpa = std.testing.allocator;
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgListOnly);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 160 }, nominalRenderer());
    defer f.deinit();

    // Three rows, one press of Tab. `focusStep` a second time from the control
    // wraps onto itself, which is what proves the rows are NOT stops.
    try std.testing.expectEqual(@as(?u64, 90), f.focusStep(null, true));
    try std.testing.expectEqual(@as(?u64, 90), f.focusStep(90, true));

    // The third row carries no message at all and is still reachable: rows are
    // `focusable` so a region exists, and roving is what keeps them out of the
    // Tab cycle. Without that, the cursor would stop after the second row.
    try std.testing.expectEqual(@as(u16, 1), f.rovingStep(90, 0, 1).?.index);
    try std.testing.expectEqual(Ui(WgMsg).rovingKey(90, 1), f.rovingStep(90, 0, 1).?.key);
    try std.testing.expectEqual(@as(u16, 2), f.rovingStep(90, 1, 1).?.index);
    try std.testing.expectEqual(@as(u16, 2), f.rovingStep(90, 2, 1).?.index);

    // Clamped, not wrapped: running off the end stops on the end.
    try std.testing.expectEqual(@as(u16, 0), f.rovingStep(90, 0, -1).?.index);

    // The row itself is the hit region, and row 0 dispatches its own message.
    const r0 = f.hit(.{ 5, 5 }).?;
    try std.testing.expectEqual(Ui(WgMsg).rovingKey(90, 0), r0.key.?);
    try std.testing.expectEqual(@as(?WgMsg, .pick_a), r0.msg);
}

test "tabs keep exactly one panel in the tree, and the strip is one tab stop" {
    const gpa = std.testing.allocator;
    const in_a = Color.rgbHex(0x123456);
    const in_b = Color.rgbHex(0x654321);

    {
        var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgTabsFirst);
        defer rt.deinit();
        var f = try rt.frame(.{ .w = 200, .h = 160 }, nominalRenderer());
        defer f.deinit();

        // The unselected panel is not merely hidden: it was never built, so
        // nothing in it can take a hit region or a focus stop.
        try std.testing.expectEqual(@as(usize, 1), countSolidPrims(f.prims, in_a));
        try std.testing.expectEqual(@as(usize, 0), countSolidPrims(f.prims, in_b));

        // One Tab stop for the whole strip.
        try std.testing.expectEqual(@as(?u64, 95), f.focusStep(null, true));

        // And the second tab is still clickable, which is the only way to get
        // to its panel. Scanned rather than guessed: pad and label width decide
        // where it starts, and a hard-coded x would encode today's font.
        var found_b = false;
        var x: f32 = 0;
        while (x < 200) : (x += 1) {
            if (f.hit(.{ x, 5 })) |h| {
                if (h.msg) |m| {
                    if (m == .pick_b) found_b = true;
                }
            }
        }
        try std.testing.expect(found_b);
    }

    {
        var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgTabsSecond);
        defer rt.deinit();
        var f = try rt.frame(.{ .w = 200, .h = 160 }, nominalRenderer());
        defer f.deinit();

        try std.testing.expectEqual(@as(usize, 0), countSolidPrims(f.prims, in_a));
        try std.testing.expectEqual(@as(usize, 1), countSolidPrims(f.prims, in_b));
    }
}

test "the widget builders hand the runtime what a call site used to assemble" {
    const gpa = std.testing.allocator;
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgView);
    defer rt.deinit();

    {
        var f = try rt.frame(.{ .w = 240, .h = 240 }, nominalRenderer());
        defer f.deinit();
        // Three payloads, one per builder, each reachable by the key its
        // builder was given -- which is the whole contract: the runtime looks
        // widgets up by key AFTER layout.
        try std.testing.expect(f.widgetAt(80).?.* == .slider);
        try std.testing.expect(f.widgetAt(81).?.* == .select);
        try std.testing.expect(f.widgetAt(82).?.* == .menu);
        const sel = switch (f.widgetAt(81).?.*) {
            .select => |v| v,
            else => unreachable,
        };
        try std.testing.expectEqual(@as(u16, 1), sel.selected);
        // Nothing is open, so the popup layer has nothing to place.
        try std.testing.expect(f.openPopup(null) == null);
    }

    // Opening the select is what the popup layer looks for, and the rows it
    // highlights are the options the builder was handed -- not a copy.
    rt.state.open = true;
    {
        var f = try rt.frame(.{ .w = 240, .h = 240 }, nominalRenderer());
        defer f.deinit();
        const popup = f.openPopup(null).?;
        const rows = Frame(WgMsg).popupRows(popup).?;
        try std.testing.expectEqual(@as(usize, 2), rows.items.len);
        try std.testing.expectEqualStrings("beta", rows.items[1].label);
    }
}

test "a slider is composed, and claims its knob's height rather than its track's" {
    const gpa = std.testing.allocator;
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgSliderOnly);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 120 }, nominalRenderer());
    defer f.deinit();

    // Track, fill, and the knob -- which is two prims, because a bordered
    // rounded rect is a face plus its stroke. A single rect would be 1, so this
    // catches the builder collapsing to the bare element the runtime would still
    // drag happily; the test would otherwise pass on a control nobody can see.
    try std.testing.expectEqual(@as(usize, 4), f.primitiveCount());
    try std.testing.expectEqual(@as(?u64, 80), f.hit(.{ 5, 11 }).?.key);
    // thickness 6 => the band is 12 tall; 13 is past it, and the column above
    // it carries no press and no key, so nothing claims the point.
    try std.testing.expect(f.hit(.{ 5, 13 }) == null);
}

fn collectSolid(prims: anytype, c: Color, out: []Rect) usize {
    var n: usize = 0;
    for (prims) |p| switch (p) {
        .quad => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = c }) and n < out.len) {
                out[n] = q.rect;
                n += 1;
            }
        },
        .rrect => |q| {
            if (std.meta.eql(q.fill, Fill{ .solid = c }) and n < out.len) {
                out[n] = q.rect;
                n += 1;
            }
        },
        else => {},
    };
    return n;
}

fn wgSeparator(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "above", .size = 12 }),
        ui.separator(.{}),
        ui.text(.{ .label = "below", .size = 12 }),
    } });
}

fn wgSeparatorVertical(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    return ui.column(.{ .children = &.{
        ui.row(.{ .children = &.{
            ui.text(.{ .label = "left", .size = 12 }),
            ui.separator(.{ .vertical = true }),
            ui.text(.{ .label = "right", .size = 12 }),
        } }),
    } });
}

test "a separator is one pixel on its thin axis and stretches on the other" {
    const gpa = std.testing.allocator;
    const th = Theme{};
    var rects: [4]Rect = undefined;

    {
        var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgSeparator);
        defer rt.deinit();
        var f = try rt.frame(.{ .w = 200, .h = 100 }, nominalRenderer());
        defer f.deinit();
        // One rule, in the border colour, exactly one pixel tall -- and wide
        // enough to prove the cross axis filled rather than shrank to the 1px
        // square the rect was constructed with.
        try std.testing.expectEqual(@as(usize, 1), collectSolid(f.prims, th.border, &rects));
        try std.testing.expectEqual(@as(f32, 1), rects[0].h);
        try std.testing.expect(rects[0].w > 100);
        // Decoration is not a target: a rule that answered a hit would swallow
        // clicks meant for the row behind it.
        try std.testing.expectEqual(@as(?Hit(WgMsg), null), f.hit(.{ rects[0].x + 2, rects[0].y }));
    }

    {
        var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgSeparatorVertical);
        defer rt.deinit();
        var f = try rt.frame(.{ .w = 200, .h = 100 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 1), collectSolid(f.prims, th.border, &rects));
        // Transposed: the row gives it the row's full height instead.
        try std.testing.expectEqual(@as(f32, 1), rects[0].w);
        try std.testing.expect(rects[0].h > 8);
    }
}

fn wgProgress(s: *WgState, ui: *Ui(WgMsg)) *Element(WgMsg) {
    _ = s;
    return ui.column(.{ .gap = 4, .children = &.{
        ui.progress(.{ .value = 0 }),
        ui.progress(.{ .value = 0.5 }),
        ui.progress(.{ .value = 1.5 }),
        ui.progress(.{ .value = std.math.nan(f32) }),
    } });
}

test "progress is proportional, clamped at both ends, and a NaN draws nothing" {
    const gpa = std.testing.allocator;
    const th = Theme{};
    var rt = Runtime(WgState, WgMsg).init(gpa, .{}, wgUpdate, wgProgress);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 140 }, nominalRenderer());
    defer f.deinit();

    var rects: [8]Rect = undefined;
    const n = collectSolid(f.prims, th.accent, &rects);
    // Four bars, two of which paint a fill: 0 paints none, 0.5 half, 1.5
    // clamped to full, and NaN paints none rather than the full bar an
    // unguarded clamp would produce.
    try std.testing.expectEqual(@as(usize, 2), n);
    // Half the width of the full one, to within a pixel of rounding.
    try std.testing.expect(@abs(rects[0].w * 2 - rects[1].w) <= 1);
    // The clamped one stops at the track, not past it.
    try std.testing.expect(rects[1].w <= 200);
}

// ---------------------------------------------------------------------------
// text fields: the seams a field needs and no widget can test alone
// ---------------------------------------------------------------------------

const FieldState = struct { edit: TextEdit = .{ .value = "hi" }, presses: i32 = 0 };

fn fieldUpdate(m: *FieldState, msg: TMsg) Action(TMsg) {
    _ = msg;
    m.presses += 1;
    return .{};
}

fn fieldView(m: *FieldState, ui: *Ui(TMsg)) *Element(TMsg) {
    var kids = [_]*Element(TMsg){
        ui.button(.{ .label = "b", .msg = .inc, .key = 1 }),
        ui.input(.{ .key = 2, .edit = &m.edit }),
    };
    return ui.column(.{ .children = &kids });
}

test "the runtime knows when a text field owns the keyboard" {
    // `text_editing` is what makes a bare-key shortcut stand down, and it is
    // derived from the PAINTED hit list every frame. Nothing else in the suite
    // builds a text field, so without this the whole derivation could be dead
    // and every shortcut would keep firing while the user types.
    const gpa = std.testing.allocator;
    var rt = Runtime(FieldState, TMsg).init(gpa, .{}, fieldUpdate, fieldView);
    defer rt.deinit();

    rt.focus = 1;
    {
        var f = try rt.frame(.{ .w = 160, .h = 80 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expect(!rt.text_editing);
        // The field painted and registered anyway -- two regions, not one.
        try std.testing.expect(f.hits.len >= 2);
    }

    rt.focus = 2;
    {
        var f = try rt.frame(.{ .w = 160, .h = 80 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expect(rt.text_editing);
    }

    // Focus on nothing is still not editing.
    rt.focus = null;
    {
        var f = try rt.frame(.{ .w = 160, .h = 80 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expect(!rt.text_editing);
    }
}

test "a masked click lands on a boundary of the value, not of the mask" {
    // "päss" is four codepoints and five bytes, and the mask draws four `?`.
    // `hitText` therefore answers in codepoints; the caret indexes the VALUE.
    // Getting this wrong puts a password caret one byte past where the click
    // was -- or splits the umlaut.
    var edit: TextEdit = .{ .value = "päss" };
    const ti = .{ .edit = &edit, .display = "????", .size = 20, .mask = true };
    const r = nominalRenderer();

    const x_two = r.measureText("??", 20).width;
    const off = caretAtClick(r, ti, x_two);
    try std.testing.expect(off == 3); // after `ä`, which is two bytes
    try std.testing.expect(off <= edit.value.len);

    // The far right is the end of the value, whatever the mask counted.
    const far = caretAtClick(r, ti, 10_000);
    try std.testing.expectEqual(edit.value.len, far);

    // And a plain field answers in bytes directly.
    const plain = .{ .edit = &edit, .display = "päss", .size = 20, .mask = false };
    try std.testing.expectEqual(@as(usize, 3), caretAtClick(r, plain, x_two));
}

test "typing into the focused field is the app's reducer, and it stays put" {
    // The value lives in the Model and the builder borrows a pointer to it, so
    // the two cannot drift: this drives the reducer the way an app's `on_text`
    // hook does, then re-frames and checks the field is holding the new text.
    const gpa = std.testing.allocator;
    var rt = Runtime(FieldState, TMsg).init(gpa, .{}, fieldUpdate, fieldView);
    defer rt.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // The caret is the insertion POINT, and a value seeded from outside leaves
    // it where the Model did: 0 here, so typing goes in front. That is the
    // contract -- `normalize` repairs a caret, it never moves one to the end to
    // be helpful -- and an app that wants to append says so.
    _ = rt.state.edit.typeBytes(arena.allocator(), "there");
    try std.testing.expectEqualStrings("therehi", rt.state.edit.value);
    try std.testing.expectEqual(@as(usize, 5), rt.state.edit.caret);

    _ = rt.state.edit.moveTo(rt.state.edit.value.len, false);
    _ = rt.state.edit.typeBytes(arena.allocator(), "!");
    try std.testing.expectEqualStrings("therehi!", rt.state.edit.value);
    try std.testing.expectEqual(@as(usize, 8), rt.state.edit.caret);

    rt.focus = 2;
    {
        var f = try rt.frame(.{ .w = 200, .h = 80 }, nominalRenderer());
        defer f.deinit();
        try std.testing.expect(rt.text_editing);
    }
    // The frame painted the value the Model holds, and the Model still owns it.
    try std.testing.expectEqualStrings("therehi!", rt.state.edit.value);
}

test "a field paints its box, its mask and its caret where the caret is" {
    // The builder had no caller for a long time, so none of this had ever run:
    // the box, the mask string, the caret quad and the hit region are all
    // asserted here rather than assumed from the code reading.
    var edit: TextEdit = .{ .value = "hello" };
    const D = struct {
        var e: *TextEdit = undefined;
        fn v(_: *u8, ui: *Ui(TMsg)) *Element(TMsg) {
            return ui.column(.{ .children = &.{
                ui.text(.{ .label = "NAME", .size = 11 }),
                ui.input(.{ .key = 1, .edit = e, .size = 16, .msg = .inc }),
                ui.input(.{ .key = 2, .edit = e, .size = 16, .mask = true, .msg = .inc }),
            } });
        }
    };
    D.e = &edit;
    const gpa = std.testing.allocator;
    var rt = Runtime(u8, TMsg).init(gpa, 0, struct {
        fn u(_: *u8, _: TMsg) Action(TMsg) {
            return .{};
        }
    }.u, D.v);
    defer rt.deinit();
    rt.focus = 1;

    var f = try rt.frame(.{ .w = 380, .h = 200 }, nominalRenderer());
    defer f.deinit();

    // Both fields registered, in tree order, with their own keys.
    try std.testing.expectEqual(@as(usize, 2), f.hits.len);
    try std.testing.expectEqual(@as(?u64, 1), f.hits[0].key);
    try std.testing.expectEqual(@as(?u64, 2), f.hits[1].key);

    // The masked field draws `?` per codepoint and never the value.
    var saw_mask = false;
    var saw_value = false;
    var caret_w: f32 = 0;
    for (f.prims) |p| switch (p) {
        .text => |t| {
            if (std.mem.eql(u8, t.bytes, "?????")) saw_mask = true;
            if (std.mem.eql(u8, t.bytes, "hello")) saw_value = true;
        },
        // The caret: a hairline quad, drawn at the insertion point.
        .quad => |q| if (q.rect.w <= 2 and q.rect.h > 8) {
            caret_w = q.rect.w;
        },
        else => {},
    };
    try std.testing.expect(saw_mask);
    try std.testing.expect(saw_value);
    try std.testing.expect(caret_w > 0);

    // ...and the runtime agrees the keyboard belongs to a field.
    try std.testing.expect(rt.text_editing);
}

test "built-in colour names resolve, and a theme's own name still wins" {
    // The point of the table: `.color = "red"` with no `.colors` entry.
    try std.testing.expectEqual(Color.rgbHex(0xff0000), builtinColor("red").?);
    try std.testing.expectEqual(Color.rgbHex(0xffffff), builtinColor("white").?);
    try std.testing.expectEqual(Color.rgbHex(0x000000), builtinColor("black").?);
    // Aliases land on the same value rather than drifting apart.
    try std.testing.expectEqual(builtinColor("cyan").?, builtinColor("aqua").?);
    try std.testing.expectEqual(builtinColor("magenta").?, builtinColor("fuchsia").?);
    try std.testing.expectEqual(builtinColor("gray").?, builtinColor("grey").?);
    // Alpha defaults to 255, so transparent has to be spelled out.
    try std.testing.expectEqual(@as(u8, 0), builtinColor("transparent").?.a);
    try std.testing.expectEqual(@as(u8, 255), builtinColor("red").?.a);
    // A name that is not a colour is still a miss.
    try std.testing.expect(builtinColor("bg") == null);

    // ORDER: the table must never shadow a theme's own name. A theme that
    // declares `.red` keeps it, which is the whole reason this is a fallback
    // rather than a lookup that runs first.
    const pal: Theme = .{};
    // No custom entry: the built-in answers, not the `text` fallback.
    try std.testing.expectEqual(Color.rgbHex(0xff0000), roleColor(pal, "red"));
    // A declared role still beats it. `text` is a built-in ROLE, and roles are
    // checked before the colour table, so this is the shadowing case that matters.
    try std.testing.expectEqual(pal.text, roleColor(pal, "text"));
}

test "a theme can write .color = .red and the builtin answers it" {
    // The read path by inspection: `readStyleField` -> `readRef` strips the dot and
    // returns a bare name, so `.red` arrives downstream as "red". This test exists
    // because inspection has been wrong here before -- `.halo` and `.stroke` both
    // read fine at every hop and reached nothing on screen.
    const App = struct {};
    const gpa = std.testing.allocator;
    // The walker reads `.styles` as a NAMED MAP: `.name = .{ fields }`. A list
    // of `.{ .name = ... }` entries parses clean and yields nothing, because the
    // reader looks for an identifier after the dot and finds a brace.
    const src =
        \\.{
        \\    .version = 3,
        \\    .theme = .{
        \\        .colors = .{ .bg = 0x000000 },
        \\        .styles = .{
        \\            .alarm = .{ .color = .red, .bg = .navy },
        \\        },
        \\    },
        \\}
    ;
    var diag: @import("theme.zig").ThemeDiag = .{};
    var loaded = try @import("theme.zig").loadTheme(App, gpa, "t.zon", src, Theme{}, &diag);
    defer @import("theme.zig").freeLoaded(App, gpa, &loaded);

    // A parse miss is a band, not a silent empty table.
    try std.testing.expectEqual(@as(usize, 0), diag.len);

    const entries = loaded.styles;
    try std.testing.expect(entries.len >= 1);

    var found = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "alarm")) {
            found = true;
            // The dot is gone: a bare name survived the read.
            try std.testing.expectEqualStrings("red", e.spec.color.?);
            try std.testing.expectEqualStrings("navy", e.spec.bg.?);
            // And it resolves to the real value, not to `text`.
            try std.testing.expectEqual(Color.rgbHex(0xff0000), roleColor(loaded.theme, e.spec.color.?));
            try std.testing.expectEqual(Color.rgbHex(0x000080), roleColor(loaded.theme, e.spec.bg.?));
        }
    }
    try std.testing.expect(found);
}
