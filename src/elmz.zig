//! elmz — an Elm / iced shaped GUI runtime for Zig 0.16+.
//!
//! The model: `view()` builds a tree of values from state, layout runs over
//! that tree, the renderer turns it into primitives / pixels, input is hit
//! tested against the same tree, and hits become messages fed back into
//! `update()`. State is a plain value; widgets are data, not retained objects.
//!
//! No allocations survive a frame: the tree lives in a per-frame arena that is
//! reset on the next `frame()` call.

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

    /// Six digits or eight, decided by the value's own magnitude.
    ///
    /// This exists because the alternative is worse than an error: a `.zon`
    /// carries a bare `u32`, and `rgbHex(0x89b4fa80)` is not the colour and not
    /// a rejection either -- it reads the LOW three bytes and returns a
    /// perfectly plausible different colour. Silent and plausible is the one
    /// outcome a loader must not produce, so the digits are counted instead of
    /// the top byte being trusted.
    pub fn hex(v: u32) Color {
        return if (v > 0xFFFFFF) rgbaHex(v) else rgbHex(v);
    }
};

pub const Size = struct { w: f32 = 0, h: f32 = 0 };

// ---------------------------------------------------------------------------
// paint: a solid colour is one case of a fill, not the whole type
// ---------------------------------------------------------------------------

/// Gradient stops: up to four colours held as VALUES, with each stop's position
/// implied by how many there are.
///
/// The positions used to be stored per stop, which cost 8 bytes each and made
/// `Stops` 36 bytes. A `Fill` carries one, and an `Element` carries five
/// optional `Fill`s -- so that little array of floats was most of the reason an
/// element was half a kilobyte. Nothing ever set a position outside the ladders
/// below, so the positions are a function of the count now.
///
/// A slice would be smaller still and is the obvious shape -- but a gradient is
/// built inside `view` and rasterised *after* `view` returns, so a slice would
/// point at a dead stack frame. Value semantics delete the whole question.
pub const Stops = struct {
    colors: [4]Color = @splat(none),
    n: u8 = 0,

    /// The colour of an unused slot. Named rather than written inline because
    /// `Color` has no field defaults, so `.{}` will not do.
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

    /// Where stop `i` sits along the axis, for a ramp of this many stops. The
    /// middle positions are the constants the old constructors stored, to the
    /// digit, so every existing ramp shades identically.
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

    /// Sample at `t`. Flat outside the end stops (every toolkit does this), so
    /// a rect taller than its axis does not snap to an edge colour.
    /// The two-stop ramp, without the loop or the span division that `at`
    /// needs to stay general. Almost every gradient in a UI is exactly two
    /// stops at 0 and 1, and this is called once per PIXEL, so the general
    /// lookup's `while` and its divide are not affordable there.
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

    /// Interpolate in PREMULTIPLIED space. A straight rgb lerp toward a
    /// transparent colour drags the midpoint toward black -- the classic muddy
    /// fade. Costs one divide per sampled pixel.
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

/// How to paint a shape. `solid` is the common case and keeps the old fast
/// path; the gradient prongs are geometry plus stops and nothing else.
///
/// `from`/`to`/`center` are NORMALISED to the painted box (0..1), never
/// pixels: an element does not know where layout will put it, and a gradient
/// in absolute pixels would slide when its element moved. `radius` is a
/// fraction of the box width.
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

    /// Linear ramp at `deg` degrees on a clock face: clockwise from 12 o'clock,
    /// naming the direction the ramp TRAVELS. 0 is bottom-to-top, 90 left-to-right,
    /// 180 top-to-bottom, 270 right-to-left, 22 whatever 22 means.
    ///
    /// Centred on the box and unit-length, so every angle spans the element and
    /// turning the ramp never shrinks it. `vgrad`/`hgrad`/`diag` are the three
    /// uncentred conveniences that predate this; they shade identically because
    /// a ramp only cares about the projection, but they keep their old vectors
    /// so existing renders do not move.
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

    /// True for the plain-colour case, which is the only one the cheap
    /// four-quad border path can draw correctly.
    pub fn isSolid(self: Fill) bool {
        return switch (self) {
            .solid => true,
            else => false,
        };
    }

    /// The colour of this fill at a point, given the box it is painted into.
    /// Pure and allocator-free, so the software rasteriser and the text shaper
    /// share one definition of "what colour is here" instead of two.
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

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, p: [2]f32) bool {
        return p[0] >= self.x and p[0] <= self.x + self.w and
            p[1] >= self.y and p[1] <= self.y + self.h;
    }

    /// Inside the rect AND inside its rounded corners. `radius` is clamped the
    /// way the rasteriser clamps it, so the claimable area and the painted area
    /// agree by construction: a corner the fill does not cover is a corner the
    /// pointer cannot claim.
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

    /// Overlap of two rects. Empty when they miss entirely, which is the only
    /// thing clipping needs to know: an empty clip draws nothing.
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

    /// Exact geometry match, for identity questions. Floats are compared
    /// directly on purpose: both sides come from the same layout arithmetic,
    /// so a tolerance would only hide a real disagreement.
    pub fn eql(self: Rect, o: Rect) bool {
        return self.x == o.x and self.y == o.y and self.w == o.w and self.h == o.h;
    }

    /// Stands in for "no clip". Finite on purpose: infinities make the
    /// intersection arithmetic produce NaN, and NaN survives clamping.
    pub const unbounded: Rect = .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };
};

/// A piece of screen geometry: the rect something occupies, plus the clip that
/// was in force there. Two elements are the same *thing* when both match
/// exactly. Overlap is not identity -- a parent overlaps the child it
/// contains, and a parent is not what was pressed.
pub const Region = struct {
    rect: Rect,
    clip: Rect,
    /// identity carried from the hit that produced it, so the pressed visual
    /// can follow a keyed element through a reorder. Comparison stays
    /// geometry-only (`eql`), which is what hover resolution relies on.
    key: ?u64 = null,
    /// The element's corner radius, carried so hover resolution and hit testing
    /// ask the same question the fill answered: does this shape cover the point?
    radius: f32 = 0,
    /// false = present but inert: it still occludes what is behind it, and it
    /// never becomes a hover or press candidate. A disabled control that
    /// simply vanished from the list would let clicks through to whatever it
    /// covers, which is the wrong meaning of "disabled".
    active: bool = true,

    pub fn eql(self: Region, rect: Rect, clip: Rect) bool {
        return self.rect.eql(rect) and self.clip.eql(clip);
    }

    pub fn holds(self: Region, p: [2]f32) bool {
        return self.rect.containsRounded(self.radius, p) and self.clip.contains(p);
    }
};

/// Renderer-agnostic draw commands. A backend either rasterises these directly
/// (software) or feeds them to a GPU pipeline (triangles + glyph quads).
/// A glow or a shadow: one shape, one colour, a ramp on the same signed
/// distance the rounded rect is already computed from.
///
/// `mode` says which SIDE of the silhouette the ramp survives on, and there is
/// one ramp for all three: opaque well inside, half at the edge, gone well
/// outside.
///
/// `.glow` keeps both halves. An opaque element hides the inner one, so it reads
/// as light around the shape; a translucent fill lets it tint the face, which is
/// the only case where `.glow` and `.outer_glow` differ.
/// `.outer_glow` keeps the outside half only.
/// `.inner_glow` is its own curve, not the shared one mirrored: full at the edge
/// and gone a whole `blur` inward, where the mirrored ramp would peak at half
/// strength and fade in `blur / 2`. It is recorded AFTER the element's fill,
/// because light inside a shape would otherwise be covered by it. Clipping `.glow` to
/// the inside is NOT an inner glow: that washes the whole face, since the ramp is
/// fully opaque once it is far enough inside.
///
/// There is no `.shadow`. A shadow is not a fourth geometry -- it is an
/// `.outer_glow` with an offset and a dark colour, and a value of its own would
/// have been a second name for one picture.
pub const Halo = struct {
    color: Color,
    /// How far the ramp runs, in pixels, straddling the silhouette: fully
    /// opaque `blur / 2` inside the edge, gone `blur / 2` outside. That
    /// straddle is what stops a shadow reading as a hard outline. An
    /// `.inner_glow` runs the longer way -- full at the edge, gone `blur`
    /// inside -- so its `blur` reads as a radius, not a half-width.
    blur: f32 = 12,
    /// Pixels the silhouette is pushed outward before the ramp starts. Without
    /// it a blurred shadow of a filled shape is barely visible.
    spread: f32 = 0,
    offset: [2]f32 = .{ 0, 0 },
    /// Degrees the light comes FROM, on the same clock face as a gradient's
    /// `dir`: clockwise from 12 o'clock, so `0` is overhead, `90` to the right,
    /// `180` directly below, `270` to the left. Null means no light source and a
    /// symmetric ramp.
    ///
    /// The two agree on the clock but not on what the number names: a gradient's
    /// `dir` is where the colour is GOING, a light is where the lamp SITS. At the
    /// same number they point opposite ways -- `Fill.angled(0)` travels upward,
    /// `.light = 0` is a lamp above. Both mean "the clock position of the thing
    /// it names", which is why this reads correctly once you ask which thing.
    ///
    /// With a light the ramp is WIDER on the side the shadow is cast toward and
    /// narrower on the lit side, which is what makes an offset shadow look cast
    /// rather than copied. It is a separate axis from `offset` on purpose: offset
    /// moves the silhouette, light shapes the falloff, and a shadow wants both.
    ///
    /// Costs a cache entry if it were baked, because it changes the mask's
    /// contents rather than its position. Rather than quantise the angle into the
    /// stencil key and spray masks whenever it animates, a lit halo takes the
    /// distance-field path -- 0.1-0.2ms for one shadow, which is the case it is
    /// for. `quality = .baked` does not override that.
    light: ?f32 = null,
    mode: Mode = .glow,
    /// How the halo is computed. `baked` is the default and the fast path: a
    /// stencil is built once and blitted, 9-sliced so its cost does not scale
    /// with the silhouette.
    ///
    /// There is deliberately no `auto`. One existed to hide a size threshold --
    /// small ramps went to the distance field on the argument that they left too
    /// little to cache -- and the benchmark inverted that at every blur measured:
    /// baked wins cold as well as hot, by 2.5-2.7x per call at every blur
    /// measured, and a bake amortises within a couple of frames. The stencil
    /// cache also plateaus -- sixteen distinct silhouettes resolve to five
    /// entries, because the aspect bucket shares them -- so the thrash case the
    /// old wording hedged against takes sixteen shapes redrawn every frame to
    /// appear at all.
    /// A value that always resolves to the default is a synonym, not a choice,
    /// so it was deleted rather than left to imply a distinction.
    ///
    /// `.sdf` is the escape hatch, and it is also the fallback: when a stencil
    /// cannot exist at all -- no allocator, or a silhouette past the mask cap --
    /// the renderer drops to the distance field itself. The two paths must stay
    /// within tolerance of each other, which the agreement tests pin.
    quality: Quality = .baked,

    /// A shadow as a picture, with the two axes wired consistently: the offset is
    /// derived from the light rather than set beside it, because a shadow that
    /// points the wrong way for its own light reads as a mistake and there is no
    /// useful case for the combination.
    ///
    /// `light_deg` is where the light comes FROM on the clock -- `0` is overhead,
    /// which is the one a UI wants almost always. `dist` is how far the silhouette
    /// is displaced, in pixels.
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

/// Frost a backdrop: what is already drawn under the element, blurred, before
/// the element paints itself. Physical rather than decorative -- it says "frost
/// this" and leaves the sampling, the passes and the falloff to the rasteriser,
/// the same way `Halo` says "glow this" instead of "run a box blur".
pub const Frost = struct {
    /// How far the blur reaches, in pixels. A radius, not a sigma: the passes
    /// are sized from it, and doubling it visibly doubles the smear.
    blur: f32 = 12,
};

pub const Primitive = union(enum) {
    quad: struct { rect: Rect, fill: Fill, clip: Rect },
    /// rounded rect: `stroke` draws a 1px outline instead of a fill
    rrect: struct { rect: Rect, radius: f32, fill: Fill, stroke: bool, clip: Rect },
    text: struct { x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect },
    /// Recorded where it has to composite: before the element's own fill for
    /// `glow` and `shadow`, after it for `inner_glow`, whose light would
    /// otherwise be covered by the shape it lives inside.
    halo: struct { rect: Rect, corner: f32, halo: Halo, clip: Rect },
    /// Blurs what is already on the canvas under `rect`. A backdrop effect, so
    /// it is recorded BEFORE the element's fill and reads the destination.
    frost: struct { rect: Rect, radius: f32, blur: f32, clip: Rect },

    /// `clip` is repeated in each prong because a Zig union has no common
    /// fields. It is the scissor rect resolved at record time, so a primitive
    /// is self-contained: replaying it needs no stack and no ordering.
    pub fn clipOf(self: Primitive) Rect {
        return switch (self) {
            .quad => |q| q.clip,
            .rrect => |q| q.clip,
            .text => |t| t.clip,
            .halo => |h| h.clip,
            .frost => |f| f.clip,
        };
    }
};

// ---------------------------------------------------------------------------
// renderer interface — a vtable, since Zig has no trait objects
// ---------------------------------------------------------------------------

/// Metrics for one line of text. `line_height` includes the font's line gap,
/// so N lines occupy `height + (N - 1) * line_height`.
/// Cap on wrapped lines per text element; extra lines are dropped rather
/// than allocated for.
pub const max_lines: usize = 32;

/// What a measurement reports. One width is not enough to lay out a row: a
/// parent has to know not just how wide a child WANTS to be but how far it can
/// be squeezed before its content breaks. `w` is the width taken at the
/// `avail_w` it was measured with; `min_w` is the floor.
///
/// There is deliberately no `pref` field. A preferred width is just "measure at
/// a large avail", and making it a field would force an immediate answer to
/// what the preferred width of wrapped text is -- which is a behaviour change
/// this contract does not want to smuggle in.
pub const Extent = struct {
    /// width taken at the avail_w this was measured with
    w: f32 = 0,
    /// height at that width
    h: f32 = 0,
    /// narrowest width that still preserves the content
    min_w: f32 = 0,
};

/// The widest unbreakable run in `bytes`, which is the floor for wrapped text.
/// `wrapLines` breaks on spaces and hard-breaks a word that cannot fit, so this
/// is the point below which it would start cutting mid-word.
fn longestWord(r: Renderer, bytes: []const u8, size: f32) f32 {
    var best: f32 = 0;
    var it = std.mem.tokenizeAny(u8, bytes, " \n\t");
    while (it.next()) |word| {
        const w = r.measureText(word, size).width;
        if (w > best) best = w;
    }
    return best;
}

/// How wide a row child ends up when the row cannot give everyone what they
/// asked for. The deficit is shared out in proportion to each child's SLACK
/// (`w - min_w`), so a text that can wrap shrinks and a button that cannot
/// keeps its size -- a fixed proportional split would shrink the button too and
/// leave the text room it does not need.
///
/// The distribution sums to exactly `inner`, because the shares are fractions
/// of the total slack and the total slack is exactly what is missing.
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
///
/// `stretch` is the default because it is what every existing render already
/// does: a child that paints its own background wants the full height, and
/// moving the default would move every pin for a cosmetic reason.
///
/// `start` and `center` exist for LABELS, which have no box of their own and
/// otherwise sit on the top edge of a taller neighbour -- a caption beside a
/// button is the case that makes the default look broken.
///
/// `baseline` is the one of the four that is about TYPE rather than boxes: the
/// children keep their own heights and are moved so their first lines of text
/// sit on a common baseline. It is what a checkbox beside its label needs, and
/// what `center` only approximates -- centring lines up box middles, so a
/// caption between a 16px control and a 24px heading lands slightly off both.
pub const RowAlign = enum { stretch, start, center, baseline };

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
    line_height: f32,
};

fn utf8SeqLen(bytes: []const u8, i: usize) usize {
    const b = bytes[i];
    if (b < 0x80) return 1;
    if ((b & 0xE0) == 0xC0) return 2;
    if ((b & 0xF0) == 0xE0) return 3;
    if ((b & 0xF8) == 0xF0) return 4;
    return 1;
}

fn utf8Count(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (n += 1) i += utf8SeqLen(bytes, i);
    return n;
}

pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Fill an outline. The path's curves are flattened by the backend, so a
    /// backend that cannot do curves has to say so rather than draw a polygon
    /// that pretends the controls were corners.
    pub fn path(self: Renderer, x: f32, y: f32, p: Path, fill: Fill, clip: Rect) void {
        self.vtable.path(self.ptr, x, y, p, fill, clip);
    }

    pub const VTable = struct {
        quad: *const fn (ptr: *anyopaque, rect: Rect, fill: Fill, clip: Rect) void,
        /// draws a rounded rect, or its 1px outline when `stroke` is set
        rrect: *const fn (ptr: *anyopaque, rect: Rect, radius: f32, fill: Fill, stroke: bool, clip: Rect) void,
        text: *const fn (ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void,
        /// A glow or shadow behind `rect`. `corner` is the element's own radius
        /// so the halo follows its shape rather than boxing it.
        halo: *const fn (ptr: *anyopaque, rect: Rect, corner: f32, h: Halo, clip: Rect) void,
        /// Blurs the destination under `rect`, in place. Must be called BEFORE
        /// the element draws, or it frosts the element too.
        frost: *const fn (ptr: *anyopaque, rect: Rect, radius: f32, blur: f32, clip: Rect) void,
        measure_text: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32) TextMetrics,
        /// Splits into lines no wider than `max_width`. Returns the count.
        /// Kept on the renderer because only the backend knows the glyph
        /// advances, and layout must break lines exactly where paint does.
        wrap_text: *const fn (
            ptr: *anyopaque,
            bytes: []const u8,
            size: f32,
            max_width: f32,
            out: [][]const u8,
        ) usize,
        /// Width of `bytes[0..index]`: where a caret before that byte sits.
        /// On the renderer for the same reason measure_text is -- only the
        /// backend knows the advances, and a caret must not disagree with the
        /// glyph it sits beside.
        advance_text: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32, index: usize) f32,
        /// The byte boundary nearest `x`: what a click selects.
        hit_text: *const fn (ptr: *anyopaque, bytes: []const u8, size: f32, x: f32) usize,
        /// Fills a closed outline at (x, y). Curves arrive UNFLATTENED:
        /// subdividing them belongs to the backend, because the tolerance is a
        /// device-pixel quantity and only the backend knows its scale.
        path: *const fn (ptr: *anyopaque, x: f32, y: f32, p: Path, fill: Fill, clip: Rect) void,
    };

    /// `clip` is required, not defaulted: every draw call names the rect it is
    /// confined to, so forgetting to clip is a compile error rather than a
    /// stale-state bug. Nothing is culled here — a fully clipped primitive
    /// still records, it just rasterises to nothing, which keeps primitive
    /// counts (and therefore the frame hashes) stable.
    pub fn quad(self: Renderer, rect: Rect, fill: Fill, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        self.vtable.quad(self.ptr, rect, fill, clip);
    }

    pub fn roundedRect(self: Renderer, rect: Rect, radius: f32, fill: Fill, stroke: bool, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        self.vtable.rrect(self.ptr, rect, radius, fill, stroke, clip);
    }

    pub fn text(self: Renderer, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void {
        if (bytes.len == 0) return;
        self.vtable.text(self.ptr, x, y, size, fill, bytes, clip);
    }

    /// A glow or shadow, drawn where the caller asked for it. The backend
    /// decides fidelity: one that cannot afford a blur is free to draw a
    /// sharp offset instead of nothing at all.
    pub fn halo(self: Renderer, rect: Rect, corner: f32, h: Halo, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        if (h.color.a == 0) return;
        self.vtable.halo(self.ptr, rect, corner, h, clip);
    }

    /// Frost the backdrop under `rect`. A backend with no read-back may ignore
    /// it, but ignoring it is not the same as approximating it: the caller asked
    /// for the pixels underneath, so a fallback would be a different picture.
    pub fn frost(self: Renderer, rect: Rect, radius: f32, blur: f32, clip: Rect) void {
        if (rect.w <= 0 or rect.h <= 0 or blur <= 0) return;
        self.vtable.frost(self.ptr, rect, radius, blur, clip);
    }

    pub fn measureText(self: Renderer, bytes: []const u8, size: f32) TextMetrics {
        return self.vtable.measure_text(self.ptr, bytes, size);
    }

    pub fn wrapText(self: Renderer, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
        return self.vtable.wrap_text(self.ptr, bytes, size, max_width, out);
    }

    /// Width of the first `index` bytes. The inverse of `hitText`, and the two
    /// are meant to round-trip: a caret placed at a boundary, then hit-tested
    /// back, must land on the same byte.
    pub fn advanceText(self: Renderer, bytes: []const u8, size: f32, index: usize) f32 {
        if (bytes.len == 0) return 0;
        return self.vtable.advance_text(self.ptr, bytes, size, @min(index, bytes.len));
    }

    /// The byte boundary under `x`. Single line only: resolving y to a line is
    /// the caller's, because only it knows how the text was wrapped.
    pub fn hitText(self: Renderer, bytes: []const u8, size: f32, x: f32) usize {
        if (bytes.len == 0) return 0;
        return self.vtable.hit_text(self.ptr, bytes, size, x);
    }
};

// ---------------------------------------------------------------------------
// element tree
// ---------------------------------------------------------------------------

/// The palette a `Ui` builds with. File scope rather than nested in `Ui` so
/// that paint can resolve a default colour for an element that never had one
/// set, without paint having to be handed a `Ui` it has no other use for.
/// The one palette. Catppuccin Mocha (palette v1.8.0) -- every value below is a
/// published Mocha hex, not a hand-tuned approximation, so the theme is
/// reproducible from https://github.com/catppuccin/palette.
///
///
/// Every colour a `view` may use lives here. Nothing outside this struct should
/// hold a colour of its own -- before this was enforced, four examples carried
/// seven local constants between them and had drifted into three different
/// window backgrounds (0x0a0c11, 0x12151d, 0x141821) plus two near-duplicate
/// selection tints, one of which was two units off the theme's own `hover`.
/// A theme you can load from a file is meaningless while that is true, because
/// half the screen would not be listening.
///
/// Roles, not widgets: `panel` is "the fill of a raised area", not "a card",
/// which is what lets one token serve panels, rows, and list items.
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
    @"error": Color = Color.rgbHex(0xf38ba8),
};

// ---------------------------------------------------------------------------
// theme files: a flat .zon becomes a Theme
// ---------------------------------------------------------------------------

/// The theme machinery -- spec, loader, diagnostics, palette guard -- lives in
/// `theme.zig`. These names are re-exported so it still reads as one library
/// from the outside: `elmz.loadTheme` stays the documented call.
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

/// The failure banner is deliberately not themed: it reports a bug, so it
/// must not be able to blend into whatever palette the app chose.
const band_h: f32 = 20;
const band_bg: Color = Color.rgbHex(0xd0342c);
const band_fg: Color = Color.rgbHex(0xfff2f0);

/// Why a frame drew its error band. The band carries the reason, because a
/// band that only says "something went wrong" costs the same pixels as one
/// that names the bug.
pub const FailKind = enum {
    /// an allocation inside `view` failed; the tree is structurally degraded
    layout_allocation,
    /// two hit regions declared the same `key`, so identity is ambiguous
    duplicate_key,
    /// the typeface the app asked for could not be read; the band carries the
    /// path, because a window of invisible text with no explanation is the
    /// worst possible answer to a missing font file
    font,
    /// the theme file could not be parsed or resolved; the detail in the band
    /// carries the file, line and column, because "theme error" alone gives
    /// the author nothing to aim at
    theme,

    /// The fallback text, used when the failure carries no detail. Callers
    /// that know more call `Ui.failFmt` and get the detail appended instead.
    pub fn message(self: FailKind) []const u8 {
        return switch (self) {
            .layout_allocation => "render failed: layout allocation",
            .duplicate_key => "render failed: duplicate key",
            .theme => "render failed: theme",
            .font => "render failed: font",
        };
    }
};

/// What the wheel needs from a scroll viewport: how tall the content is and
/// how much of it is on screen. Travels with the hit region rather than being
/// stored, because only paint knows the content height.
pub const ScrollView = struct {
    content_h: f32,
    view_h: f32,
    /// The other axis. A container can overflow both ways at once, and the
    /// wheel needs both extents to know which delta to spend.
    content_w: f32 = 0,
    view_w: f32 = 0,
};

/// A request to move one viewport. Two forms because the two things an app
/// actually wants are different: go to a place, or move by an amount.
pub const ScrollChange = union(enum) {
    to: struct { key: u64, offset: f32 },
    by: struct { key: u64, dy: f32 },
};

/// One viewport's offset, keyed by the element's `key`. Owned by the runtime
/// so that no message ever carries a continuous value: a drag or a wheel tick
/// changes this, and the next frame reads it.
pub const ScrollSlot = struct { key: u64 = 0, offset: f32 = 0, offset_x: f32 = 0 };

/// Scrollbar geometry, in logical units. The thumb has a floor or it becomes
/// impossible to grab on a long list; the strip is thin and sits over the
/// trailing edge, because a gutter would change the content width the moment
/// overflow began -- which rewraps, which can remove the overflow.
pub const scrollbar_w: f32 = 6;
pub const scrollbar_min_thumb: f32 = 24;
/// How wide the thumb's claim on the pointer is. Deliberately wider than the
/// strip it paints: a 6px target is not grabbable. It is the whole reason the
/// thumb is allowed to sit in front of the content, so it must earn the space
/// by being usable -- and it grows LEFTWARD, into the content, because the
/// right edge is the viewport's own border.
pub const scrollbar_grab: f32 = 14;

/// The root container's scroll identity. Any constant works -- what matters is
/// that it is stable across frames, because the scroll store outlives one.
pub const scroll_path_root: u64 = 0x9e3779b97f4a7c15;

/// One step down the tree. FNV-1a over the parent's hash and the child index:
/// cheap, allocator-free, and identical for the same position in the same tree,
/// which is all a scroll slot needs. A reordered list therefore moves its
/// offsets, which is the honest answer -- the store is positional.
pub fn pathChild(parent: u64, index: usize) u64 {
    var h = parent ^ 0xcbf29ce484222325;
    h *%= 0x100000001b3;
    h ^= @as(u64, @intCast(index)) +% 1;
    h *%= 0x100000001b3;
    return h;
}

/// A thumb that has taken the pointer. Carried on the hit region instead of a
/// message, because a drag produces a continuous value and nothing that is
/// continuous may ride in a Msg. The key travels here rather than on
/// `Hit.key`: keys are frame-unique identity, and a thumb is the same element
/// as the viewport it belongs to, so reusing the key would report a collision.
pub const ScrollDrag = struct {
    key: u64,
    view: ScrollView,
    /// Which offset this thumb writes. A container can carry two thumbs, and a
    /// drag that guessed the axis from the numbers would be wrong the moment
    /// both axes overflow.
    horizontal: bool = false,
};

/// Which way a control runs. A separate name rather than a `vertical: bool`,
/// so the call site reads as what it is and there is somewhere for a third
/// value to go that is not a second boolean.
pub const Orientation = enum { horizontal, vertical };

/// A slider that has taken the pointer. It carries its own geometry because the
/// pointer-to-value mapping needs it, and the frame that produced the region is
/// gone by the time the pointer moves. It carries NO grab offset on purpose: a
/// slider's value is where the pointer is, so remembering how far from the knob
/// the press landed would shift the whole range by that distance.
pub const SliderDrag = struct {
    key: u64,
    /// The track as laid out in the frame the press happened in. A resize
    /// mid-drag re-maps against the old rect, which is the right failure: the
    /// value follows the pointer it was given, not a rect that moved under it.
    rect: Rect,
    /// Into the Model, never the arena: a drag outlives the frame that began it.
    value: *f32,
    min: f32,
    max: f32,
    /// null = continuous.
    step: ?f32,
    orientation: Orientation,
};

/// What has taken the pointer for continuous motion. A union rather than a
/// second optional field beside `ScrollDrag`, so "held" has exactly one
/// representation: two nullables would let both be set and leave every reader
/// to work out which one wins.
pub const Drag = union(enum) {
    thumb: ScrollDrag,
    slider: SliderDrag,
};

/// Where a pointer sits across a slider's range, 0..1. Vertical is INVERTED: a
/// fader is loudest at the top, so a control that grew upward but increased
/// downward would be the surprising one.
fn sliderFraction(rect: Rect, orientation: Orientation, p: [2]f32) f32 {
    const t = switch (orientation) {
        .horizontal => if (rect.w > 0) (p[0] - rect.x) / rect.w else 0,
        .vertical => if (rect.h > 0) (rect.y + rect.h - p[1]) / rect.h else 0,
    };
    return std.math.clamp(t, 0, 1);
}

/// The value under the pointer, quantised to the grid when there is one. The
/// grid is computed from `min` on every call instead of being accumulated, so a
/// long drag cannot drift off it the way `v + step` does.
pub fn sliderValueAt(d: SliderDrag, p: [2]f32) f32 {
    return quantise(d, d.min + sliderFraction(d.rect, d.orientation, p) * (d.max - d.min));
}

/// One step TOWARD the pointer, never to it. Clicking far along a stepped track
/// walks the value there a click at a time rather than jumping as far as you
/// happened to click. A DRAG is the opposite and uses `sliderValueAt`: the two
/// entry points differ on purpose, and they share `sliderFraction` so they can
/// never disagree about where the pointer is.
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

/// What a toast is telling the app. Four values rather than two because the
/// alternative -- folding warning into error -- is how a palette decision
/// becomes something a widget can no longer express. Each one must have a
/// role in `Theme` and a filing in `familyOf`.
pub const Severity = enum { info, success, warning, @"error" };

/// How a self-intersecting outline decides what is inside it. Both rules are
/// needed: an icon's magnifier glass is a ring under either, but a hole in a
/// gear is only a hole if you say which rule you meant.
pub const FillRule = enum { nonzero, evenodd };

pub const PathOp = enum { move, line, quad, cubic, close };

/// An outline in the caller's own coordinates.
///
/// Curves stay curves. The BACKEND flattens them, in DEVICE space, because a
/// flattening tolerance is measured in pixels -- subdivide before the scale is
/// applied and you are guessing how much each curve will be magnified.
///
/// `ops` and `points` are borrowed and read only for the duration of the call.
pub const Path = struct {
    ops: []const PathOp,
    /// One point per `move`/`line`, two per `quad` (control then end), three
    /// per `cubic` (two controls then end), none for `close`. Deliberately the
    /// same shape as the SVG `d` grammar, so a parsed icon maps across without
    /// a translation step in between.
    points: []const [2]f32,
    rule: FillRule = .nonzero,
};

/// Where a popup sits relative to the anchor it belongs to. Same box either
/// way; the difference is which edge stays put.
pub const PopupAnchor = enum {
    /// A control that expanded: grow evenly above and below, centred on the
    /// field, so the field looks like it opened rather than like a list
    /// appeared beside it. There is no above/below flip here -- centring
    /// makes it unnecessary, which is why the flip exists only for menus.
    centred,
    /// A command that drops out of its trigger. Left edges aligned, and it
    /// flips above when there is no room below: a menu centred on its button
    /// would read as a rendering fault.
    below,
};

/// Rows past this scroll inside a fixed-height box. ODD ON PURPOSE: the box is
/// centred on its anchor, so an even count splits unevenly around the middle
/// row, and the list would look off by half a row.
pub const popup_max_rows: usize = 5;

/// One row's height. A constant because the box height has to be knowable
/// before any row is measured -- and it is what keeps the box from resizing
/// as the active row moves.
pub const popup_row_h: f32 = 26;

pub const PopupLayout = struct {
    rect: Rect,
    /// Index of the first row painted. The box height does NOT change with
    /// it: the window slides inside a fixed frame, which is what stops the
    /// whole popup jumping on every arrow press.
    first: usize,
    count: usize,
};

/// The box a popup occupies, and which rows of a long list it shows.
///
/// Pure, and free of the frame: the arithmetic is where the mistakes live --
/// a box that resizes per keypress, a menu that opens off-screen -- so it is
/// worth testing without rasterising anything.
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

/// One row of a select, menu or list. `msg` is optional because a menu
/// separator is an item that claims space and does nothing; `disabled` is kept
/// because `Element.disabled` already records a region inert, so a greyed row
/// blocks the click instead of letting it fall through.
pub fn Choice(comptime M: type) type {
    return struct {
        label: []const u8 = "",
        msg: ?M = null,
        disabled: bool = false,
    };
}

/// What a control must tell the runtime that the app cannot.
///
/// This is the SIBLING of `Geometry`, not a variant of it. `Geometry` answers
/// "how do I measure, paint, clip and descend a scroll offset" and it must
/// never learn that widgets exist -- five switches walk it, and the file has
/// nineteen `else => {}` arms, so a new variant there is a silent subtree-skip
/// waiting to happen. This union answers the one different question the
/// runtime asks AFTER layout: is this a control, and what does it need?
///
/// It carries messages, so it is generic over `M` exactly as `Hit` is.
///
/// The value is reached through a pointer into the frame arena. That pointer
/// is valid for the frame that built it and not one moment longer: a widget
/// payload must never be cached across frames, unlike a `*f32` into the app's
/// own Model, which lives as long as the app does. `Frame.hit` strips it from
/// the copy it hands out for precisely this reason.
pub fn Widget(comptime M: type) type {
    return union(enum) {
        /// A value control. The runtime maps the pointer to a number and
        /// writes it through `value`, because only the runtime sees motion
        /// between frames. A Msg says that it changed; it carries nothing,
        /// since raw pointer data is consumed at the edge.
        slider: struct {
            /// Into the Model, not the arena: a drag outlives the frame that
            /// started it, and app state is the one thing that does.
            value: *f32,
            min: f32 = 0,
            max: f32 = 1,
            /// null = continuous. `step` is allowed, never enforced: a
            /// stepped drag quantises as it goes, and the click rule is a
            /// nudge of one step toward the pointer.
            step: ?f32 = null,
            orientation: Orientation = .horizontal,
            msg: M,
        },
        /// A collapsed list of options. Geometry, dismissal and typeahead all
        /// belong to the runtime popup layer, which needs the anchor's real
        /// laid-out rect -- something `view` cannot know, because layout runs
        /// after `view` returns.
        select: struct {
            open: bool,
            selected: u16,
            /// A pointer into the Model so hover, arrows and typeahead write
            /// one number. Two copies would let the highlight disagree with
            /// what Enter activates.
            active: *?u16,
            options: []const Choice(M),
            /// Emitted by the closed field, to toggle.
            msg: M,
        },
        /// Commands rather than a value. Same popup layer, different geometry:
        /// a menu drops below its trigger and flips, where a select grows
        /// centred on its field.
        menu: struct {
            open: bool,
            active: *?u16,
            items: []const Choice(M),
            toggle: M,
        },
        /// A notification. The Model owns whether it exists; the runtime owns
        /// the clock, because a toast that expires needs the poll timeout
        /// shortened or it simply never fires.
        toast: struct {
            severity: Severity = .info,
            ttl_ms: u32 = 4000,
            /// Emitted on expiry or on click.
            msg: M,
        },
    };
}

pub fn Hit(comptime M: type) type {
    return struct {
        rect: Rect,
        clip: Rect,
        /// The message a release here dispatches, or null for a region that
        /// only routes input -- a scroll viewport claims pointer position
        /// without ever producing a message.
        msg: ?M = null,
        /// Set on a scroll viewport. Null on every other region, which is what
        /// keeps wheel routing to one walk of the hit list instead of a second
        /// traversal of the tree.
        scroll: ?ScrollView = null,
        /// The tree-path identity of the container that scrolled, for regions
        /// produced by IMPLICIT scrolling. Separate from `key` because it is
        /// runtime-computed, not app-authored: the wheel and the thumb store
        /// their offset under this, so an app never invents a viewport key and
        /// the duplicate-key guard never sees a synthesized one.
        scroll_id: ?u64 = null,
        /// Set on a scroll THUMB, which claims the pointer as a drag rather
        /// than as a press. Recorded with no `key` and no `msg`: it dispatches
        /// nothing, and its identity is the viewport's, so the duplicate-key
        /// scan stays meaningful.
        drag: ?Drag = null,
        /// The focus scope this region was recorded inside, or null at the
        /// root. Assigned after the subtree paints, so an element cannot
        /// disagree with its own container about where it lives.
        scope: ?u64 = null,
        /// Set on a row of a roving control: the control's key. Null on
        /// everything else, including the control itself.
        roving: ?u64 = null,
        roving_index: u16 = 0,
        /// Identity of the element that produced this region, if it declared
        /// one. A keyed press re-binds to the element carrying the same key
        /// instead of to a rectangle, so it survives the content reordering
        /// around it. Keys are unique within a frame: a second region carrying
        /// the same key is reported through the error band rather than quietly
        /// rebinding a press to whichever twin it met first.
        key: ?u64 = null,
        /// mirrors the element's `disabled`: recorded so a press can be
        /// cancelled when the element it claimed turns inert mid-gesture.
        active: bool = true,
        /// Corner radius, so a rounded control is only claimed where it is
        /// actually painted -- its bounding box is not its shape.
        radius: f32 = 0,
        /// Whether Tab may land here. Recorded because only the frame knows
        /// document order -- an app that had to rebuild it would be
        /// reimplementing layout. A `key` is required too: focus is named, so
        /// an unkeyed element has nothing for it to hold on to.
        focusable: bool = false,
        /// The control payload, if this element is a widget. Borrowed from the
        /// frame arena and valid only for the frame that recorded it;
        /// `Frame.hit` strips it before the app sees a Hit so no caller can
        /// hold one past its life, and only the runtime's own walks ever read
        /// it.
        widget: ?*const Widget(M) = null,
    };
}

/// A Hit with the borrowed widget payload removed.
///
/// Everything an app can hold has to come through here. The payload points into
/// the frame arena, which is reset at the START of the next frame, while a
/// `Press` deliberately survives across frames -- so a captured Hit carrying
/// one would be a live dangling pointer sitting in a struct. Nothing
/// dereferences it today, which is exactly the kind of safety that is one
/// refactor away from being gone.
fn published(comptime M: type, h: Hit(M)) Hit(M) {
    var c = h;
    c.widget = null;
    return c;
}

/// Enqueues a hit region clipped to what is actually visible. A fully clipped
/// element is not pressable, so `Frame.hitTest` stays a plain `contains` loop
/// with no clip logic of its own.
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
///
/// The three hot slots carry a `?Color` plus a `?Fill` gradient override rather
/// than one optional, because a bare `Color` does not coerce into the tagged
/// union and `.bg = .{ .solid = c }` at every call site was worse than the pair.
/// `bgFill`/`fgFill`/`borderFill` resolve that pair, and they are the only place
/// the precedence lives.
///
/// A `Style` is a VALUE: it can be returned from a function, named once and
/// reused, and asserted in a test without rendering anything. That is the whole
/// point of it existing as a type rather than eight assignments to an element.
pub const Style = struct {
    bg: ?Color = null,
    /// gradient override for `bg`
    bg_grad: ?Fill = null,
    fg: ?Color = null,
    fg_grad: ?Fill = null,
    border: ?Color = null,
    border_grad: ?Fill = null,
    /// `null` means the caller did not specify, which is what lets a widget
    /// merge a caller style over its own defaults and still let someone force
    /// a square corner with `radius = 0`.
    radius: ?f32 = null,
    pad: ?f32 = null,
    /// Appearance, not layout: an app can set a glow on any element, and a
    /// widget that wants a shadow by default can put one here.
    halo: ?Halo = null,
    /// Blur of what is behind this element. Nothing shows unless something is
    /// drawn under it, so it pairs with a translucent `bg`.
    frost: ?Frost = null,

    pub fn bgFill(self: Style, fallback: ?Fill) ?Fill {
        return resolveFill(self.bg, self.bg_grad, fallback);
    }
    pub fn fgFill(self: Style, fallback: ?Fill) ?Fill {
        return resolveFill(self.fg, self.fg_grad, fallback);
    }
    pub fn borderFill(self: Style, fallback: ?Fill) ?Fill {
        return resolveFill(self.border, self.border_grad, fallback);
    }
};

/// The one rule for a slot: the gradient wins over the flat colour, because a
/// caller who set a gradient meant it. `fallback` is what the geometry or the theme
/// defaults to when the caller set neither.
fn resolveFill(solid: ?Color, grad: ?Fill, fallback: ?Fill) ?Fill {
    if (grad) |g| return g;
    if (solid) |c| return .{ .solid = c };
    return fallback;
}

pub fn Element(comptime M: type) type {
    return struct {
        const Self = @This();

        geometry: Geometry,
        /// inner padding for containers
        pad: f32 = 0,
        /// gap between children, uniform by definition
        gap: f32 = 0,
        /// Space reserved AROUND this child inside the slot its container gives
        /// it. Four fields rather than a before/after pair because the pair
        /// could only ever name the parent's MAIN axis -- a row read it as left,
        /// a column as top, and neither could express "3px above this swatch"
        /// inside a row at all.
        ///
        /// MAIN axis: a row spends `margin_left` then `margin_right`; a column
        /// `margin_top` then `margin_bottom`. They replace `gap` for this one
        /// child, which is how uneven spacing is expressed: a number on the
        /// child, never a phantom spacer element in the child list.
        /// CROSS axis: the margins shrink the slot the child is aligned inside,
        /// so `.center` centres between them and `.stretch` fills what is left.
        /// Either way a margin is space the child does not get.
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        /// overrides the measured width (useful inside rows)
        width: ?f32 = null,
        height: ?f32 = null,
        /// fills this element's rect before anything inside it is painted
        bg: ?Color = null,
        /// gradient override for `bg`; wins over the flat colour when set
        bg_grad: ?Fill = null,
        /// what this element draws with on top of `bg`: text colour, control
        /// label, bar fill. Appearance lives on the element rather than inside
        /// `Geometry`, so the geometry describes structure only — which is what lets a
        /// widget take its colours from the theme instead of needing a variant
        /// per look.
        fg: ?Color = null,
        fg_grad: ?Fill = null,
        /// A glow or shadow behind this element, following its corner radius.
        /// Appearance only: no layout cost, no hit region, no children moved.
        halo: ?Halo = null,
        /// Blur of what is already drawn behind this element, before the
        /// element's own fill. Cost is area, not circumference, so it is for
        /// cards and bars, not for text.
        frost: ?Frost = null,
        /// A halo drawn only while the pointer is over this element, merged
        /// over `halo`. Kept separate from `halo` for the same reason
        /// `hover_bg` is separate from `bg`: the hovered state is derived
        /// during paint, so an app cannot compute it in `view`, and it must
        /// not have to keep a copy of the resting look to restore later.
        hover_halo: ?Halo = null,
        /// 1px inset outline, drawn inside the rect so it costs no layout
        border: ?Color = null,
        border_grad: ?Fill = null,
        /// wrap text to the width layout gives this element
        wrap: bool = false,
        /// corner rounding; 0 = square. Clamped to half the shorter side.
        radius: f32 = 0,
        /// makes any element pressable, not just buttons
        on_press: ?M = null,
        /// What the runtime needs to ask this node after layout, if it is a
        /// Declares that this subtree is a FOCUS SCOPE keyed by this element.
        /// Focus does not leave it while it is open: with a dialog up, Tab
        /// cycles the dialog instead of walking the page behind it. The regions
        /// the subtree records are stamped with this key on the way out, so no
        /// parameter has to be threaded through `paint`.
        focus_scope: bool = false,
        /// Set by a builder on rows belonging to a roving control. Such a row is
        /// NOT a Tab stop -- the control is -- which is what collapses a
        /// twenty-row list into one press of Tab.
        roving: ?u64 = null,
        roving_index: u16 = 0,
        /// control. Declared by a widget builder and owned by the frame arena;
        /// an app never writes it, and the builder owns the pairing with
        /// `geometry` so the two cannot disagree.
        widget: ?*const Widget(M) = null,
        /// confine every descendant to this element's rect (rect clip only;
        /// rounded corners are not cut yet). Off by default, so nothing that
        /// does not ask for it changes.
        clips: bool = false,
        /// Vertical scroll offset for a `scroll` geometry, in logical units.
        /// INJECTED BY THE RUNTIME from its keyed store, between `view` and
        /// layout -- writing it in `view` is meaningless, because the next
        /// frame overwrites it. Ask for a change with `Action.scroll`.
        scroll_offset: f32 = 0,
        /// Runtime-written: this container's TREE PATH, hashed by the injection
        /// walk. Implicit scrolling needs an identity for every container the
        /// app did not key, and the path is the only one that exists without
        /// asking. Never set this by hand.
        scroll_key: ?u64 = null,
        /// The horizontal half of `scroll_offset`: both axes scroll on every
        /// container kind, so both offsets have to exist.
        scroll_offset_x: f32 = 0,
        /// background while the pointer is over this element. null = no
        /// hover feedback, so nothing that does not ask for it changes.
        /// Still a `Fill` rather than the `Color` + `_grad` pair the three
        /// hot slots use: no gradient hover exists yet, so splitting it would
        /// be a pair of fields bought on speculation. Give it the same shape
        /// when one does.
        hover_bg: ?Fill = null,
        /// background while this element owns the press.
        press_bg: ?Fill = null,
        /// refuses input: no hit region, no hover, no press visual. Layout and
        /// drawing are untouched, so a disabled control keeps its shape and
        /// only loses its affordances and its contrast.
        disabled: bool = false,
        /// Whether this element may hold focus. Focus is only meaningful for a
        /// KEYED element: focus names an identity, and an unkeyed element has
        /// none, so `focusable` alone draws nothing.
        focusable: bool = false,
        /// In a ROW, take a share of the width left over after every non-grow
        /// child and the gaps have been paid for. Equal shares, floored at the
        /// child's own `min_w` -- overflow rather than clipping, same rule as
        /// the squeeze. Ignored in a column; vertical fill is a separate idea
        /// and nothing needs it yet.
        grow: bool = false,
        /// Cross-axis placement of this row's children. See `RowAlign`.
        row_align: RowAlign = .stretch,
        /// identity for keyed children. When set, a press that starts here
        /// re-binds to the element carrying the same key on later frames
        /// rather than to a rectangle, so it survives reordering. Unique among
        /// siblings; unset means the old rect-based behaviour.
        key: ?u64 = null,
        /// Displacement from a stack's content origin, in logical units.
        /// IGNORED by every other geometry: flow containers decide where children
        /// go, a stack asks each child where it wants to be. Negative values
        /// are legal and are how a tooltip sits above its anchor.
        offset: [2]f32 = .{ 0, 0 },

        /// What this element IS structurally: how it measures, how it paints,
        /// what it clips, and how a scroll offset descends through it.
        ///
        /// `Geometric` rather than "widget" on purpose. `text` and `button`
        /// carry their bytes and label because that content is what the
        /// geometry applies to, not an interaction model — which is why a
        /// widget must never add a variant here. Appearance lives on the
        /// element instead (see `fg`), so a geometry cannot imply a look.
        pub const Geometry = union(enum) {
            column: struct { children: []const *Self },
            row: struct { children: []const *Self },
            /// A viewport over ONE child: the child is laid out at its full
            /// height and painted shifted by `scroll_offset`, clipped to this
            /// element's box. The offset is runtime state, so a viewport is
            /// something an app declares and never animates by hand.
            scroll: struct { child: *Self },
            text: struct { bytes: []const u8, size: f32 },
            button: struct { label: []const u8, size: f32 },
            bar: struct { value: f32 },
            /// Children share ONE origin, each displaced by its own `offset`.
            /// The only container where siblings may overlap, and the only way
            /// an element paints outside the box flow gave it -- which is what
            /// a dropdown, a tooltip and a modal all are.
            ///
            /// Later children paint later, so they sit on top AND appear later
            /// in the hit list, where `hit` walks from the end. Overlap and
            /// z-order therefore agree without either one being declared.
            stack: struct { children: []const *Self },
            /// a plain sized box; the only geometry with no intrinsic size
            rect: void,
        };

        /// This element's appearance, read out as one value.
        pub fn style(self: *const Self) Style {
            return .{
                .bg = self.bg,
                .bg_grad = self.bg_grad,
                .fg = self.fg,
                .fg_grad = self.fg_grad,
                .border = self.border,
                .border_grad = self.border_grad,
                .radius = self.radius,
                .pad = self.pad,
                .halo = self.halo,
                .frost = self.frost,
            };
        }

        /// The ONLY intended writer of the appearance fields, and the reason
        /// they are grouped: one call replaces eight assignments, so the reader
        /// sees the whole look at the point the element is made instead of
        /// tracking statements that may follow later.
        ///
        /// This SETS, it does not merge -- a caller passing `.{}` gets the
        /// defaults back, `radius` and `pad` included. Call it once, at
        /// construction. Zig has no field privacy, so post-hoc assignment still
        /// compiles; this is the short path, not an enforced boundary.
        pub fn applyStyle(self: *Self, s: Style) void {
            self.bg = s.bg;
            self.bg_grad = s.bg_grad;
            self.fg = s.fg;
            self.fg_grad = s.fg_grad;
            self.border = s.border;
            self.border_grad = s.border_grad;
            self.radius = s.radius orelse 0;
            self.pad = s.pad orelse 0;
            self.halo = s.halo;
            self.frost = s.frost;
        }

        /// Overlay `s` on what this element already has: only the fields the
        /// caller actually set are written.
        ///
        /// This is the one widgets need. A button carries its own theme
        /// defaults, and `applyStyle` would blank them the moment a caller
        /// passed `.{}`. Same reason `radius`/`pad` are optional in `Style`:
        /// "unset" and "zero" have to be different answers or a caller cannot
        /// ask for square corners on a rounded widget.
        pub fn mergeStyle(self: *Self, s: Style) void {
            if (s.bg) |v| self.bg = v;
            if (s.bg_grad) |v| self.bg_grad = v;
            if (s.fg) |v| self.fg = v;
            if (s.fg_grad) |v| self.fg_grad = v;
            if (s.border) |v| self.border = v;
            if (s.border_grad) |v| self.border_grad = v;
            if (s.radius) |v| self.radius = v;
            if (s.pad) |v| self.pad = v;
            if (s.halo) |v| self.halo = v;
            if (s.frost) |v| self.frost = v;
        }

        /// Totals a row shares out. Computed by ONE function so measure and
        /// paint cannot drift: they disagreed once about a child's height and
        /// the symptom was a control painted outside the box it was measured
        /// in, which no test caught because both halves were self-consistent.
        const RowFit = struct {
            total_w: f32 = 0,
            total_min: f32 = 0,
            /// Everything the grow shares cannot eat: the non-grow children
            /// with their spacing, plus the gaps between everyone.
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

        /// Final width for one row child. A grow child is paid out of the
        /// leftover at the width it was measured at, so a row that cannot pay
        /// falls back to the ordinary squeeze -- which already floors everyone
        /// at `min_w`.
        fn rowWidth(cs: Extent, ch: *const Self, fit: RowFit) f32 {
            if (ch.grow and fit.n_grow > 0 and fit.total_w <= fit.inner) {
                const n: f32 = @floatFromInt(fit.n_grow);
                return @max((fit.inner - fit.fixed_w) / n, cs.min_w);
            }
            return rowChildWidth(cs, fit.total_w, fit.total_min, fit.inner);
        }

        /// Distance from this element's TOP edge down to the baseline of the
        /// first line of text it will draw, or null when it draws none.
        ///
        /// `w` and `h` are the box it will ACTUALLY paint in, not what it asked
        /// for. A button centres its label in whatever height it is handed, so
        /// its baseline moves when a row stretches it and cannot be answered
        /// from the geometry alone.
        ///
        /// A container borrows the first baseline it contains -- its first line
        /// box, the same rule CSS uses. A nested row would strictly want the
        /// deepest child, but a label column and a stacked label+detail are the
        /// cases that actually occur, and both are answered by the first.
        fn textBaseline(self: *const Self, r: Renderer, w: f32, h: f32) ?f32 {
            switch (self.geometry) {
                .text => |t| return self.pad + r.measureText(t.bytes, t.size).ascent,
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
                .bar, .rect, .stack, .scroll => return null,
            }
        }

        /// Height (and resolved width) at `avail_w` — the width the parent is
        /// about to give this element.
        ///
        /// `avail_w` exists so wrapping does not have to be told its width by
        /// the call site, where the number is a guess that layout has not
        /// computed yet. It is the same number paint lays the element out
        /// with, which is what keeps measure and paint breaking lines in the
        /// same place.
        pub fn measure(self: *const Self, r: Renderer, avail_w: f32) Extent {
            var s: Extent = switch (self.geometry) {
                .text => |t| blk: {
                    const ts = r.measureText(t.bytes, t.size);
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

        /// A column's content extent: the sum down its main axis, and the widest
        /// child across it. Both are needed now that either axis can overflow.
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

        /// A row's cross-axis extent: the tallest child, floored at the box so a
        /// row that fits reports nothing to scroll.
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

        /// THE RULE, in one place: compare content extent against the box the
        /// parent painted, per axis. No declaration, no height, no key. The box
        /// comes from the parent, so whichever container the content actually
        /// overflows is the one that scrolls -- the window is just the outermost
        /// case of it.
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

        /// Everything a scrolling container owes the runtime: the region the
        /// wheel targets, and whichever thumbs apply. One function for every
        /// kind, so a column and a stack cannot disagree about what "scrolled"
        /// means.
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
                .key = self.key,
                .active = !self.disabled,
                .focusable = self.focusable and self.key != null,
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

        /// The vertical scrollbar, painted last so content cannot cover it, and
        /// only when there is something to scroll.
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

        /// The thumb's grab region: wider than the 6px it draws, because a strip
        /// that can only be hit on the pixel it paints is not draggable in
        /// practice.
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
            var bg_now: ?Fill = self.style().bgFill(null);
            if (!self.disabled) {
                if (ptr.held) |held| {
                    if (self.press_bg) |pc| {
                        // Rect identity keeps a press through a reflow; key
                        // identity keeps it through a reorder, where the rect
                        // is no longer the one that was pressed.
                        if (held.eql(rect, clip) or (self.key != null and held.key == self.key)) bg_now = pc;
                    }
                } else if (self.hover_bg) |hc| {
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
            if (self.hover_bg != null) {
                if (hov.out) |out| try out.append(gpa, .{ .rect = rect, .clip = clip, .key = self.key, .active = !self.disabled, .radius = self.radius });
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
            const fg_now: Fill = if (self.disabled) .{ .solid = th.text_muted } else self.style().fgFill(.{ .solid = th.text }).?;
            // Focus is the third derived appearance, after press and hover: the
            // runtime names a key, the element asks whether it is that key. A
            // focused control shows the accent as its border, so apps never
            // paint a ring themselves and the theme still owns the colour.
            // Focus names an IDENTITY, not a rectangle: the runtime says which
            // key holds it, and each element asks whether that key is its own.
            // An unkeyed element can never match, so `focusable` alone draws
            // nothing -- which is the intended contract, not a special case.
            const focused = self.focusable and !self.disabled and
                self.key != null and hov.focus != null and hov.focus.? == self.key.?;
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
                if (ptr.held) |held| break :blk held.eql(rect, clip) or (self.key != null and held.key == self.key);
                if (hov.target) |target| break :blk target.eql(rect, clip);
                if (ptr.pos) |p| break :blk rect.containsRounded(self.radius, p) and clip.contains(p);
                break :blk false;
            };
            const halo_now: ?Halo = if (hovered) self.hover_halo orelse self.halo else self.halo;
            // Backdrop first: a frost reads what is behind it, so it has to run
            // while the destination is still the backdrop and not the element.
            if (self.frost) |fr| r.frost(rect, self.radius, fr.blur, clip);
            if (self.radius > 0) {
                if (fill_now) |c| r.roundedRect(rect, self.radius, c, false, clip);
                if (border_now) |c| r.roundedRect(rect, self.radius, c, true, clip);
            } else {
                if (fill_now) |c| r.quad(rect, c, clip);
                if (border_now) |b| {
                    // A gradient border cannot be four thin quads: each quad's
                    // box is 1px on its short axis, so the ramp would restart
                    // per edge and collapse to a single stop. Route it through
                    // the SDF stroke, which evaluates against the element rect.
                    if (!b.isSolid()) {
                        r.roundedRect(rect, 0, b, true, clip);
                    } else {
                        r.quad(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, b, clip);
                        r.quad(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, b, clip);
                        r.quad(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, b, clip);
                        r.quad(.{ .x = rect.x + rect.w - 1, .y = rect.y, .w = 1, .h = rect.h }, b, clip);
                    }
                }
            }
            // One emission point, one order, for every mode. `.glow` keeps BOTH
            // halves of the ramp, so the inner one has to land on the face -- under
            // the fill it would simply be covered. `.outer_glow` cuts the inner
            // half and `.inner_glow` cuts the outer one, so the same order is
            // correct for all three and no mode needs a rule of its own.
            if (halo_now) |h| r.halo(rect, self.radius, h, clip);
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
            const viewport_claims_this = std.meta.activeTag(self.geometry) == .scroll and self.key != null;
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
            if (!viewport_claims_this and (self.on_press != null or (self.focusable and self.key != null) or self.widget != null)) {
                try hitAppend(M, hits, gpa, .{
                    .rect = rect,
                    .clip = clip,
                    .msg = self.on_press,
                    .key = self.key,
                    .active = !self.disabled,
                    .radius = self.radius,
                    .focusable = self.focusable and self.key != null,
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
                        r.text(ix, iy, t.size, fg_now, fit.bytes, tclip);
                        if (fit.ellipsis) r.text(ix + fit.width, iy, t.size, fg_now, ellipsis, tclip);
                    } else {
                        var buf: [max_lines][]const u8 = undefined;
                        const n = r.wrapText(t.bytes, t.size, iw, &buf);
                        const ts = r.measureText(t.bytes, t.size);
                        for (buf[0..n], 0..) |line, i| {
                            if (line.len == 0) continue;
                            r.text(ix, iy + @as(f32, @floatFromInt(i)) * ts.line_height, t.size, fg_now, line, tclip);
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
                    var fill = rect;
                    fill.w = rect.w * std.math.clamp(b.value, 0, 1);
                    r.quad(fill, self.style().fgFill(.{ .solid = th.accent }).?, clip);
                },

                .rect => {},

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
        }
    };
}

// ---------------------------------------------------------------------------
// builders — the `view` DSL
// ---------------------------------------------------------------------------

pub fn Ui(comptime M: type) type {
    return struct {
        const Self = @This();
        pub const Elem = Element(M);

        arena: std.heap.ArenaAllocator,
        theme: Theme = .{},
        /// Per-role gradient overrides from the theme file. Empty means every
        /// role paints its flat colour, which is the default look.
        gradients: Gradients = .{},
        /// Which key holds focus, mirrored from the runtime before `view` runs.
        /// The READ half of `Action.focus`: a widget can ask whether the caret
        /// belongs to it, and the app does not have to keep a second copy of
        /// the answer in its Model. Null means nothing holds focus.
        focus: ?u64 = null,
        /// Seconds since the runtime started, mirrored before `view` runs.
        ///
        /// The READ half of the frame clock, and the reason `view` needs none
        /// of its own: a caret that blinks, a tooltip held long enough to
        /// appear, a toast that expires and a typeahead buffer that lapses ask
        /// the same question, and the runtime is the one thing that always
        /// knows the answer.
        ///
        /// A number rather than a callback, so the tree stays a value and a
        /// headless test can hand `view` whatever time it likes.
        elapsed: f32 = 0,
        /// Seconds since the last key or text event. Read here so "do not
        /// blink while typing" costs the app nothing, and so four widgets
        /// cannot disagree about when typing stopped.
        since_input: f32 = 0,
        /// How long the pointer has rested on the current region, reset when
        /// it moves to a different one. The tooltip delay and nothing else:
        /// `elapsed` says how long the app has run, not how long you have been
        /// looking at that particular thing.
        hover_since: f32 = 0,
        /// The READ side of the scroll store: whatever the runtime is holding
        /// for each keyed viewport. Read-only here because the offset is not
        /// the app's to write -- the wheel and the thumb own it.
        scrolls: []const ScrollSlot = &.{},
        /// set when an allocation failed. The frame is then structurally
        /// degraded rather than aborted, which is what lets `view` be
        /// infallible. The runner reports it.
        failed: bool = false,
        /// which failure `failed` refers to; only meaningful when failed
        fail_kind: FailKind = .layout_allocation,
        /// Detail for the band, formatted in place. A fixed buffer rather
        /// than a slice: the text must not depend on an allocation, because
        /// the band exists to report failures, and a slice into the per-frame
        /// arena would dangle the moment that arena is reset.
        fail_buf: [192]u8 = undefined,
        fail_len: usize = 0,

        /// A failure raised from outside a build; see `failExternal`. Zero
        /// length means none, and that is the whole state.
        ext_kind: FailKind = .theme,
        ext_buf: [192]u8 = undefined,
        ext_len: usize = 0,
        /// stands in for any node that could not be allocated
        dead: Elem,

        /// Current offset for a keyed viewport, or 0 if it has never moved.
        ///
        /// Read from `scrolls`, the slice this frame gave `view`, so it is the
        /// answer to use INSIDE `view`. Outside a frame, `scrollOffset` reads
        /// the runtime's own store instead.
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

        /// Records a failure that has no detail beyond its kind.
        pub fn failWith(self: *Self, kind: FailKind) void {
            self.failed = true;
            self.fail_kind = kind;
            self.fail_len = 0;
        }

        /// Records a failure and formats the explanation into the band's own
        /// buffer. `noinline` is not needed -- this is cold -- but it is
        /// deliberately allocation-free, so a failing frame can always report
        /// itself even when the allocator is what failed.
        pub fn failFmt(self: *Self, kind: FailKind, comptime f: []const u8, args: anytype) void {
            self.failed = true;
            self.fail_kind = kind;
            // Truncation is fine here: the band is one line, and a message
            // that long is a diagnostic nobody could read in it anyway.
            const written = std.fmt.bufPrint(&self.fail_buf, f, args) catch self.fail_buf[0..];
            self.fail_len = written.len;
        }

        /// Raise a failure that OUTLIVES the next frame reset.
        ///
        /// `frame()` zeroes per-build state on entry, which is right for an
        /// allocation that failed inside `view` -- it describes that build and
        /// nothing else. A theme file that will not parse is not a property of
        /// a build: the runner discovers it between frames, and the band has to
        /// still be saying so on the frame after. Same band, two lifetimes.
        pub fn failExternal(self: *Self, kind: FailKind, comptime f: []const u8, args: anytype) void {
            self.ext_kind = kind;
            const written = std.fmt.bufPrint(&self.ext_buf, f, args) catch self.ext_buf[0..];
            self.ext_len = written.len;
        }

        /// The outside world recovered. Nothing else clears this, because
        /// nothing outside the caller knows the condition is gone.
        pub fn clearExternal(self: *Self) void {
            self.ext_len = 0;
        }

        /// What the band paints: the formatted detail when there is one, the
        /// kind's own text otherwise.
        pub fn failMessage(self: *const Self) []const u8 {
            if (self.fail_len == 0) return self.fail_kind.message();
            return self.fail_buf[0..self.fail_len];
        }

        fn alloc(self: *Self) Allocator {
            return self.arena.allocator();
        }

        /// Put a widget payload in the FRAME ARENA and hand back a pointer.
        ///
        /// The arena is exactly the right lifetime for this: `view` builds it,
        /// the runtime reads it after layout, the frame ends. Anything that has
        /// to outlive a frame points at the Model instead -- which is why
        /// `slider.value`, `select.active` and `menu.active` are pointers and
        /// not values here.
        ///
        /// Optional rather than a failure pointer: the caller has an element in
        /// hand and can return it without the payload, which is a widget that
        /// paints but does not respond. Silently returning a dangling or shared
        /// pointer would be far worse.
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

        /// Which of the two text roles a label uses. A field rather than a
        /// second builder: `ui.muted` was within two calls of `ui.text`, so two
        /// near-identical functions were being carried for one word at the
        /// call site.
        pub const Tone = enum { normal, muted };

        /// What every builder accepts, repeated in each opts struct rather than
        /// shared through a nested field. Duplication on purpose: nesting it
        /// would push every call site down a level (`.common.style = ...`) to
        /// save a library-internal repetition the caller never sees.
        fn finish(self: *Self, e: *Elem, o: anytype) *Elem {
            _ = self;
            // Every margin an options struct happens to offer is applied.
            // @hasField rather than a required set: a builder that never wants
            // margins should not have to declare four zeroes to say so.
            inline for (.{ "margin_left", "margin_right", "margin_top", "margin_bottom" }) |m| {
                if (@hasField(@TypeOf(o), m)) @field(e, m) += @field(o, m);
            }
            if (o.key) |k| e.key = k;
            if (o.disabled) e.disabled = true;
            // Any element is pressable once it carries a message; that is the
            // generic hit path, not a button privilege. Buttons pass it in as
            // `msg`, everything else through this.
            if (o.on_press) |msg| e.on_press = msg;
            if (o.clips) e.clips = true;
            if (o.hover_bg) |v| e.hover_bg = v;
            if (o.hover_halo) |v| e.hover_halo = v;
            if (o.press_bg) |v| e.press_bg = v;
            // Caller last: a caller who set a field meant it, and `mergeStyle`
            // writes only the fields they actually set.
            e.mergeStyle(o.style);
            return e;
        }

        pub const TextOpts = struct {
            label: []const u8,
            size: f32 = 14,
            tone: Tone = .normal,
            wrap: bool = false,
            on_press: ?M = null,
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over
            /// the element. Its own field rather than a colour on `halo`
            /// because a glow and a shadow are the same type with different
            /// geometry: hover usually swaps the geometry, not just the tint.
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
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over
            /// the element. Its own field rather than a colour on `halo`
            /// because a glow and a shadow are the same type with different
            /// geometry: hover usually swaps the geometry, not just the tint.
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

        /// A row is a column with the axis swapped: identical options, and
        /// keeping them one declaration means a new field lands in both.
        pub const RowOpts = ColumnOpts;

        pub const ButtonOpts = struct {
            label: []const u8,
            msg: M,
            size: f32 = 16,
            on_press: ?M = null,
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over
            /// the element. Its own field rather than a colour on `halo`
            /// because a glow and a shadow are the same type with different
            /// geometry: hover usually swaps the geometry, not just the tint.
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

        pub const BarOpts = struct {
            value: f32,
            on_press: ?M = null,
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over
            /// the element. Its own field rather than a colour on `halo`
            /// because a glow and a shadow are the same type with different
            /// geometry: hover usually swaps the geometry, not just the tint.
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

        pub const RectOpts = struct {
            width: f32,
            height: f32,
            on_press: ?M = null,
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
            /// halo drawn INSTEAD of `style.halo` while the pointer is over
            /// the element. Its own field rather than a colour on `halo`
            /// because a glow and a shadow are the same type with different
            /// geometry: hover usually swaps the geometry, not just the tint.
            hover_halo: ?Halo = null,
            style: Style = .{},
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

        /// Same options as a column; `gap` is meaningless and ignored, because
        /// no two stack children are adjacent. One declaration keeps a new
        /// option landing in every container at once.
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
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
            hover_halo: ?Halo = null,
            width: ?f32 = null,
            /// The viewport's height. Without one a viewport is as tall as its
            /// content and can never overflow, so this is the field that makes
            /// scrolling possible at all.
            height: ?f32 = null,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            /// Required for a scrollable viewport: the offset is stored under
            /// this key, so an unkeyed viewport sits at zero forever.
            key: ?u64 = null,
            disabled: bool = false,
            /// accepted and redundant: a viewport always clips.
            clips: bool = false,
        };

        /// A viewport over one child. Clipped by construction -- that is what
        /// makes it a viewport -- and never given an offset by the app: the
        /// wheel and the thumb move it, and the runtime holds the number.
        pub fn scroll(self: *Self, o: ScrollOpts) *Elem {
            const e = self.mk(.{ .scroll = .{ .child = o.child } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.clips = true;
            return self.finish(e, o);
        }

        /// Text. `fg` is only set for `tone = .muted`: leaving it unset is the
        /// paint default, so the common case writes one fewer field.
        pub fn text(self: *Self, o: TextOpts) *Elem {
            const e = self.mk(.{ .text = .{ .bytes = o.label, .size = o.size } });
            e.wrap = o.wrap;
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            if (o.tone == .muted) e.fg = self.theme.text_muted;
            return self.finish(e, o);
        }

        /// Format into the frame arena and hand back the slice.
        ///
        /// This is what makes a formatted label a first-class citizen: it lives
        /// as long as the frame (a stack buffer would dangle, since the tree
        /// outlives `view`), and the caller can then use a full opts struct --
        /// including `tone` -- instead of being stuck with a positional
        /// builder that has no appearance surface.
        pub fn fmt(self: *Self, comptime f: []const u8, args: anytype) []const u8 {
            return std.fmt.allocPrint(self.alloc(), f, args) catch {
                self.failWith(.layout_allocation);
                return "";
            };
        }

        /// The short form for the common case: formatted text at one size, no
        /// other appearance. Kept because it is two thirds of the call sites,
        /// and because `fmt` reads worse when nothing else is set.
        pub fn textFmt(self: *Self, comptime f: []const u8, args: anytype, size: f32) *Elem {
            return self.text(.{ .label = self.fmt(f, args), .size = size });
        }

        pub fn button(self: *Self, o: ButtonOpts) *Elem {
            const e = self.mk(.{ .button = .{ .label = o.label, .size = o.size } });
            // The click is an element fact, not a button fact: the generic
            // `on_press` hit path already registers it, so the button geometry
            // does not need to carry the message as well.
            e.on_press = o.msg;
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.hover_bg = .{ .solid = self.theme.hover };
            e.press_bg = .{ .solid = self.theme.pressed };
            // The geometry's own look, then the caller's overlay.
            e.applyStyle(.{ .bg = self.theme.control, .fg = self.theme.text });
            return self.finish(e, o);
        }

        pub fn bar(self: *Self, o: BarOpts) *Elem {
            const e = self.mk(.{ .bar = .{ .value = o.value } });
            if (o.width) |v| e.width = v;
            if (o.height) |v| e.height = v;
            e.applyStyle(.{ .bg = self.theme.control, .fg = self.theme.accent });
            return self.finish(e, o);
        }

        /// A rule between things: decoration, so no key, no message and no
        /// focus. Anything clickable is a control, not this.
        ///
        /// Orientation is EXPLICIT, not inferred from the parent. A builder
        /// cannot see the container it will land in, and inferring it would mean
        /// answering at paint time a question the call site already knows.
        /// `.vertical = true` is the row case.
        pub const SeparatorOpts = struct {
            vertical: bool = false,
            /// Whole pixels: at 1.5 density a 1px rule is already the thinnest
            /// line that draws without going soft.
            thickness: f32 = 1,
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
        };

        pub fn separator(self: *Self, o: SeparatorOpts) *Elem {
            const t = @max(1.0, o.thickness);
            const e = self.rect(.{ .width = t, .height = t, .style = .{ .bg = self.theme.border } });
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

        /// Determinate only. An indeterminate bar is an animation, and this
        /// widget would then need the frame clock to mean anything at all.
        pub const ProgressOpts = struct {
            /// 0 to 1. Clamped, not asserted: a progress value is usually
            /// derived from data the app does not fully control.
            value: f32,
            width: ?f32 = null,
            height: f32 = 6,
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
            const e = self.bar(.{ .value = v, .width = o.width, .height = o.height });
            e.margin_left = o.margin_left;
            e.margin_right = o.margin_right;
            e.margin_top = o.margin_top;
            e.margin_bottom = o.margin_bottom;
            return e;
        }

        /// Sets the margin on BOTH axes' leading edge. Kept for call sites that
        /// predate the four-field form and are correct either way: only the axis
        /// the parent actually lays out along is ever read, so a column sees the
        /// top margin and ignores the left one. New code should name the side.
        pub fn spaceBefore(self: *Self, e: *Elem, size: f32) *Elem {
            _ = self;
            e.margin_left += size;
            e.margin_top += size;
            return e;
        }

        /// A plain sized box. Formerly you had to abuse `bar` for this.
        pub fn rect(self: *Self, o: RectOpts) *Elem {
            const e = self.mk(.rect);
            e.width = o.width;
            e.height = o.height;
            return self.finish(e, o);
        }

        pub const SliderOpts = struct {
            key: u64,
            /// Into the Model, not the arena: a drag outlives the frame that
            /// started it, and app state is the one thing that does.
            value: *f32,
            min: f32 = 0,
            max: f32 = 1,
            /// null = continuous. Allowed, never enforced: a drag quantises as
            /// it goes, and a click is a nudge of one step toward the pointer.
            step: ?f32 = null,
            orientation: Orientation = .horizontal,
            msg: M,
            /// Travel along the long axis.
            length: f32 = 120,
            /// Thickness of the TRACK. The knob is twice this, and the hit
            /// rect is the knob's diameter.
            thickness: f32 = 6,
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            disabled: bool = false,
        };

        /// A value control: track, filled portion and knob, composed from rects
        /// because none of the three is a primitive worth adding.
        ///
        /// The value is read at view time, so every child's geometry is known
        /// before layout. None of the children sets `on_press` or `focusable`,
        /// so none of them records a hit region and the stack's own region is
        /// the only claim on the rect -- which is why composing cannot create a
        /// z-order argument against the pointers that are meant to hit it.
        ///
        /// The hit rect is the KNOB's diameter in the thin axis, not the
        /// track's thickness. A 6px track is ungrabbable otherwise, and the
        /// runtime drags whatever region it is given, so widening the region is
        /// the whole fix.
        pub fn slider(self: *Self, o: SliderOpts) *Elem {
            const span = o.max - o.min;
            const raw: f32 = if (span == 0) 0 else (o.value.* - o.min) / span;
            // clamp, not @min/@max by hand: it maps NaN to a bound instead of
            // letting it through, and a NaN here would place the knob and the
            // fill at a coordinate the rasteriser has to defend against.
            const f = std.math.clamp(raw, 0, 1);
            const d = o.thickness * 2;
            const inset = (d - o.thickness) / 2;
            const along = o.length * f;
            const knob_max = @max(o.length - d, 0);

            const track = self.rect(.{
                .width = if (o.orientation == .horizontal) o.length else o.thickness,
                .height = if (o.orientation == .horizontal) o.thickness else o.length,
                .style = .{ .bg = self.theme.control, .radius = o.thickness / 2 },
            });
            const fill = self.rect(.{
                .width = if (o.orientation == .horizontal) along else o.thickness,
                .height = if (o.orientation == .horizontal) o.thickness else along,
                .style = .{ .bg = self.theme.accent, .radius = o.thickness / 2 },
            });
            const knob = self.rect(.{
                .width = d,
                .height = d,
                .style = .{ .bg = self.theme.bg, .border = self.theme.border, .radius = d / 2 },
            });

            switch (o.orientation) {
                // Vertical is INVERTED: a fader is loudest at the top, so a
                // control that grew upward but increased downward would be the
                // surprising one.
                .horizontal => {
                    track.offset = .{ 0, inset };
                    fill.offset = .{ 0, inset };
                    knob.offset = .{ std.math.clamp(along - d / 2, 0, knob_max), 0 };
                },
                .vertical => {
                    track.offset = .{ inset, 0 };
                    fill.offset = .{ inset, o.length - along };
                    knob.offset = .{ 0, std.math.clamp(o.length - along - d / 2, 0, knob_max) };
                },
            }

            const root = self.stack(.{
                .children = &.{ track, fill, knob },
                .width = if (o.orientation == .horizontal) o.length else d,
                .height = if (o.orientation == .horizontal) d else o.length,
            });
            root.key = o.key;
            root.margin_left = o.margin_left;
            root.margin_right = o.margin_right;
            root.margin_top = o.margin_top;
            root.margin_bottom = o.margin_bottom;
            root.disabled = o.disabled;
            // A key plus `focusable` is what makes the region exist at all;
            // without them the payload would never reach the runtime.
            root.focusable = true;
            root.widget = self.payload(.{ .slider = .{
                .value = o.value,
                .min = o.min,
                .max = o.max,
                .step = o.step,
                .orientation = o.orientation,
                .msg = o.msg,
            } });
            return root;
        }

        pub const SelectOpts = struct {
            key: u64,
            open: bool,
            selected: u16,
            /// A pointer into the Model so hover, arrows and typeahead write one
            /// number. Two copies would let the highlight disagree with what
            /// Enter activates.
            active: *?u16,
            options: []const Choice(M),
            /// Emitted by the closed field, to toggle.
            msg: M,
            /// Shows when nothing is selected, and when `selected` is out of
            /// range -- which is a state a caller can reach without meaning to.
            placeholder: []const u8 = "",
            size: f32 = 16,
            width: ?f32 = null,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            disabled: bool = false,
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
        };

        /// A collapsed list of options. The field is a button because that is
        /// what it is: a focusable, clickable box showing the current value.
        /// Placement, dismissal and typeahead belong to the runtime popup
        /// layer, which needs the anchor's real laid-out rect -- something
        /// `view` cannot know, because layout runs after `view` returns.
        pub fn select(self: *Self, o: SelectOpts) *Elem {
            const label = if (o.selected < o.options.len)
                o.options[o.selected].label
            else
                o.placeholder;
            const e = self.button(.{
                .label = label,
                .msg = o.msg,
                .size = o.size,
                .width = o.width,
                .style = o.style,
                .margin_left = o.margin_left,
                .margin_right = o.margin_right,
                .margin_top = o.margin_top,
                .margin_bottom = o.margin_bottom,
                .disabled = o.disabled,
                .hover_bg = o.hover_bg,
                .press_bg = o.press_bg,
            });
            e.key = o.key;
            e.focusable = true;
            e.widget = self.payload(.{ .select = .{
                .open = o.open,
                .selected = o.selected,
                .active = o.active,
                .options = o.options,
                .msg = o.msg,
            } });
            return e;
        }

        pub const MenuOpts = struct {
            key: u64,
            /// The trigger's own caption. `Widget.menu` deliberately carries no
            /// label: a menu is commands plus the button that reveals them, and
            /// the caption belongs to the button.
            label: []const u8,
            open: bool,
            active: *?u16,
            items: []const Choice(M),
            toggle: M,
            size: f32 = 16,
            width: ?f32 = null,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            disabled: bool = false,
            hover_bg: ?Fill = null,
            press_bg: ?Fill = null,
        };

        /// The menu node IS its trigger, so its laid-out rect is the popup's
        /// anchor with no cross-node key lookup and no "anchor is not in this
        /// frame" case. Same rule as select, different geometry: a menu drops
        /// below its trigger and flips, where a select grows centred on field.
        pub fn menu(self: *Self, o: MenuOpts) *Elem {
            const e = self.button(.{
                .label = o.label,
                .msg = o.toggle,
                .size = o.size,
                .width = o.width,
                .style = o.style,
                .margin_left = o.margin_left,
                .margin_right = o.margin_right,
                .margin_top = o.margin_top,
                .margin_bottom = o.margin_bottom,
                .disabled = o.disabled,
                .hover_bg = o.hover_bg,
                .press_bg = o.press_bg,
            });
            e.key = o.key;
            e.focusable = true;
            e.widget = self.payload(.{ .menu = .{
                .open = o.open,
                .active = o.active,
                .items = o.items,
                .toggle = o.toggle,
            } });
            return e;
        }

        pub const ControlKind = enum { checkbox, radio, toggle };

        pub const ControlOpts = struct {
            key: u64,
            label: []const u8,
            kind: ControlKind = .checkbox,
            /// Drawn from the Model, never held by the widget: a control that
            /// remembered its own state would disagree with the value the app
            /// fed back on the next frame.
            checked: bool,
            /// Emitted on activation. The Model flips `checked`; nothing here
            /// does, so the same builder works for a value derived from
            /// somewhere else entirely.
            msg: M,
            /// Set membership for a radio. Nothing reads it at paint time -- it
            /// exists so a later roving group can find its members without
            /// needing a container element to hang them on.
            group: u16 = 0,
            box: f32 = 16,
            gap: f32 = 8,
            size: f32 = 14,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
        };

        /// Checkbox, radio and switch: one builder because the three differ in
        /// shape and in nothing else. All three take `checked` in and emit a
        /// message out, so none of them owns state.
        ///
        /// The WHOLE ROW is the hit region -- box, gap and label -- because a
        /// 16px box is a small target and the label is what the reader is
        /// actually aiming at. That is why the row carries the key and the
        /// message rather than the box.
        pub fn control(self: *Self, o: ControlOpts) *Elem {
            const th = self.theme;
            const mark = if (o.checked) th.accent else th.control;
            const box: *Elem = switch (o.kind) {
                .checkbox => blk: {
                    const outer = self.rect(.{
                        .width = o.box,
                        .height = o.box,
                        .style = .{ .bg = mark, .border = th.border, .radius = 3 },
                    });
                    if (!o.checked) break :blk outer;
                    // A filled square alone reads as "loud" without saying what
                    // it is. The tick is a square in the page colour for now --
                    // at 16px the silhouette is the whole legibility budget, and
                    // a real check needs path data this library does not have.
                    const tick = o.box * 0.5;
                    // `offset` is on the Element, not on RectOpts: it is
                    // placement, and a rect builder that took it would be
                    // deciding where its parent puts it.
                    const mark_e = self.rect(.{
                        .width = tick,
                        .height = tick,
                        .style = .{ .bg = th.bg, .radius = 1 },
                    });
                    mark_e.offset = .{ (o.box - tick) * 0.5, (o.box - tick) * 0.5 };
                    break :blk self.stack(.{ .width = o.box, .height = o.box, .children = &.{ outer, mark_e } });
                },
                .radio => blk: {
                    const outer = self.rect(.{
                        .width = o.box,
                        .height = o.box,
                        .style = .{
                            .bg = th.control,
                            .border = if (o.checked) th.accent else th.border,
                            .radius = o.box * 0.5,
                        },
                    });
                    if (!o.checked) break :blk outer;
                    const dot = o.box * 0.4;
                    const dot_e = self.rect(.{
                        .width = dot,
                        .height = dot,
                        .style = .{ .bg = th.accent, .radius = dot * 0.5 },
                    });
                    dot_e.offset = .{ (o.box - dot) * 0.5, (o.box - dot) * 0.5 };
                    break :blk self.stack(.{ .width = o.box, .height = o.box, .children = &.{ outer, dot_e } });
                },
                .toggle => blk: {
                    const w = o.box * 2;
                    const knob = o.box - 4;
                    const track = self.rect(.{
                        .width = w,
                        .height = o.box,
                        .style = .{ .bg = mark, .border = th.border, .radius = o.box * 0.5 },
                    });
                    // The knob travels rather than the track changing shape: a
                    // track that grew would move the label every time the value
                    // flipped, which is the one thing a toggle must not do.
                    const knob_e = self.rect(.{
                        .width = knob,
                        .height = knob,
                        .style = .{ .bg = th.bg, .radius = knob * 0.5 },
                    });
                    knob_e.offset = .{ if (o.checked) w - knob - 2 else 2, 2 };
                    break :blk self.stack(.{ .width = w, .height = o.box, .children = &.{ track, knob_e } });
                },
            };
            const line = self.row(.{
                .children = &.{ box, self.text(.{ .label = o.label, .size = o.size }) },
                .gap = o.gap,
                .key = o.key,
                .on_press = o.msg,
                .style = o.style,
                .margin_left = o.margin_left,
                .margin_right = o.margin_right,
                .margin_top = o.margin_top,
                .margin_bottom = o.margin_bottom,
            });
            // Start, not the middle: the box sits on the FIRST LINE's box, so a
            // label that wraps keeps the box beside its opening words instead of
            // drifting to the centre of the paragraph. Set afterwards because
            // `row_align` is a property of the row element, not an option of the
            // container builders.
            line.row_align = .start;
            // A Tab stop, unlike a toast: this is a control the keyboard must
            // be able to reach. `row` has no `focusable` option because a row is
            // a container -- being focusable is the one thing a control asks for
            // that its container kind cannot express.
            line.focusable = true;
            return line;
        }

        pub const ToastOpts = struct {
            key: u64,
            text: []const u8,
            severity: Severity = .info,
            ttl_ms: u32 = 4000,
            /// Emitted on expiry and on a click. The same message both ways on
            /// purpose: "the reader closed it" and "it timed out" are one
            /// decision for the Model, which is to forget it.
            msg: M,
            size: f32 = 13,
            /// Width of the severity bar down the left edge.
            bar_width: f32 = 3,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
        };

        /// The colour a severity is drawn in. Public because an app composing
        /// its own notification -- a banner, a status line -- should not have to
        /// repeat the mapping to stay in step with the toast.
        /// Names for the three shapes `control` paints. Thin on purpose: the
        /// kind is the only thing they decide, so behaviour has one home and
        /// cannot drift between a toggle and a checkbox that look different.
        pub fn checkbox(self: *Self, o: ControlOpts) *Elem {
            var c = o;
            c.kind = .checkbox;
            return self.control(c);
        }

        pub fn radio(self: *Self, o: ControlOpts) *Elem {
            var c = o;
            c.kind = .radio;
            return self.control(c);
        }

        /// A toggle is a checkbox with different paint: same key, same message,
        /// same checked-in / message-out ownership. Only the silhouette moves.
        pub fn toggle(self: *Self, o: ControlOpts) *Elem {
            var c = o;
            c.kind = .toggle;
            return self.control(c);
        }

        pub fn severityColor(self: *Self, s: Severity) Color {
            return switch (s) {
                .info => self.theme.accent,
                .success => self.theme.success,
                .warning => self.theme.warning,
                .@"error" => self.theme.@"error",
            };
        }

        /// A notification. The Model owns whether it exists; the runtime owns
        /// when it stops, because the clock is the one thing `view` cannot see.
        ///
        /// Carries `key` and `on_press` for two separate reasons: a click is how
        /// a reader dismisses it early, and the keyed hit region is also how the
        /// runtime finds the rect it needs to pause the countdown while the
        /// pointer is over it. NOT focusable -- a notification must never take
        /// a Tab stop away from the thing underneath.
        pub fn toast(self: *Self, o: ToastOpts) *Elem {
            // Height 0 on purpose. A stretched row paints every child at the
            // row's inner height regardless of what the child measured, so the
            // stripe takes no part in sizing the row (the label does that) and
            // still spans it exactly -- including a label that wraps. Giving it
            // an explicit height would instead make a two-line toast shorter
            // than the label inside it.
            const stripe = self.rect(.{
                .width = o.bar_width,
                .height = 0,
                .style = .{ .bg = self.severityColor(o.severity) },
            });
            const e = self.row(.{
                .children = &.{ stripe, self.text(.{ .label = o.text, .size = o.size }) },
                .gap = 8,
                .style = .{
                    .bg = self.theme.panel,
                    .border = self.theme.border,
                    .radius = 6,
                    .pad = 8,
                },
                .margin_left = o.margin_left,
                .margin_right = o.margin_right,
                .margin_top = o.margin_top,
                .margin_bottom = o.margin_bottom,
            });
            // Caller style last, like every other builder, but before the
            // payload: a style that changes the fill must not be able to drop
            // the widget and leave a toast the runtime never expires.
            e.mergeStyle(o.style);
            e.key = o.key;
            e.on_press = o.msg;
            e.widget = self.payload(.{ .toast = .{
                .severity = o.severity,
                .ttl_ms = o.ttl_ms,
                .msg = o.msg,
            } });
            return e;
        }

        /// A row's key, derived from its control's key and its index.
        ///
        /// `roving` collapses N rows into one Tab stop, and the runtime cursor
        /// holds a KEY rather than an index -- `rovingStep` skips a row with no
        /// key at all, so an unkeyed row can be passed over but never landed
        /// on, and the mechanism silently does nothing. Derived here rather
        /// than declared by the caller so nobody hand-writes twenty keys that
        /// then have to stay in step with the row list.
        pub fn rovingKey(owner: u64, index: u16) u64 {
            return owner *% 0x100000001b3 +% (@as(u64, index) +% 1);
        }

        pub const Tab = struct {
            label: []const u8,
            /// Dispatched on click, and by Enter or Space when the cursor is on
            /// this tab. A Msg carries no payload, so "which tab" is the
            /// identity of the message rather than a number inside it.
            msg: M,
            /// Painted only while this tab is the selected one. Empty is legal:
            /// a strip governing content the app draws elsewhere is a normal
            /// shape, not a degenerate one.
            children: []const *Elem = &.{},
        };

        pub const TabsOpts = struct {
            key: u64,
            /// The Model decides. Out of range paints an empty panel instead of
            /// asserting: a rebuilt view can drop a tab the Model still names,
            /// and a library that panics on that turns a stale index into a
            /// crash on the frame after a content change.
            selected: u16,
            tabs: []const Tab,
            size: f32 = 16,
            gap: f32 = 4,
            pad: f32 = 10,
            width: ?f32 = null,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            disabled: bool = false,
        };

        /// A tab strip over its panels, where only the selected tab's children
        /// are in the tree at all -- the others are never built, so nothing
        /// hidden can take a focus stop or a hit region.
        ///
        /// Every tab is a ROVING row, exactly as in `ui.list`: the strip is one
        /// Tab stop and arrows move between tabs, which is what makes a ten-tab
        /// window cost one press of Tab rather than ten.
        ///
        /// The live tab is marked with a `.selected` fill, `.text` in place of
        /// `.text_muted`, and an `.accent` border. An UNDERLINE indicator would
        /// be the usual shape and is the one thing deliberately not done: a bar
        /// spanning the tab needs the tab's own laid-out width, and `view`
        /// cannot measure text without becoming a function of the font. The
        /// border carries the same signal -- `.selected` and `.hover` are only
        /// 1.2:1 apart, so something in the accent colour has to say which is
        /// live -- without inventing a second measurement path.
        pub fn tabs(self: *Self, o: TabsOpts) *Elem {
            const th = self.theme;
            const btns = self.alloc().alloc(*Elem, o.tabs.len) catch {
                self.failWith(.layout_allocation);
                return self.column(.{ .children = &.{} });
            };
            for (o.tabs, 0..) |t, i| {
                const live = i == @as(usize, o.selected);
                const label = self.text(.{
                    .label = t.label,
                    .size = o.size,
                    .style = .{ .fg = if (live) th.text else th.text_muted },
                });
                const b = self.row(.{
                    .children = &.{label},
                    .style = .{
                        .bg = if (live) th.selected else null,
                        .border = if (live) th.accent else null,
                        .pad = o.pad,
                    },
                    .hover_bg = .{ .solid = th.hover },
                    .on_press = t.msg,
                });
                b.key = rovingKey(o.key, @intCast(i));
                b.roving = o.key;
                b.roving_index = @intCast(i);
                b.disabled = o.disabled;
                btns[i] = b;
            }
            const panel = if (@as(usize, o.selected) < o.tabs.len)
                self.column(.{ .children = o.tabs[o.selected].children })
            else
                self.column(.{ .children = &.{} });
            const strip = self.row(.{ .children = btns, .gap = o.gap });
            const root = self.column(.{
                .children = &.{ strip, panel },
                .gap = o.gap,
                .width = o.width,
                .style = o.style,
                .margin_left = o.margin_left,
                .margin_right = o.margin_right,
                .margin_top = o.margin_top,
                .margin_bottom = o.margin_bottom,
                .disabled = o.disabled,
            });
            root.key = o.key;
            root.focusable = true;
            return root;
        }

        pub const ListOpts = struct {
            key: u64,
            rows: []const Choice(M),
            /// The committed row, owned by the Model. PAINTING ONLY: the
            /// cursor is the runtime's, because "where the keyboard was last"
            /// is not data, and restoring it into a different list after a
            /// remount would land on an index that no longer means the same
            /// thing.
            selected: ?u16 = null,
            /// Uniform on purpose. A list whose rows differ in height needs the
            /// cursor position to be computed rather than multiplied, and
            /// nothing has asked for that.
            row_h: f32 = 26,
            size: f32 = 16,
            width: ?f32 = null,
            gap: f32 = 0,
            pad: f32 = 8,
            style: Style = .{},
            margin_left: f32 = 0,
            margin_right: f32 = 0,
            margin_top: f32 = 0,
            margin_bottom: f32 = 0,
            disabled: bool = false,
        };

        /// A vertical list as ONE Tab stop, with arrows moving inside it.
        ///
        /// No widget payload, and that is a deliberate reading of the rules
        /// rather than an omission: a list is a STRUCTURE, not a control. Every
        /// behaviour it needs already exists -- roving is `Element.roving`,
        /// selection belongs to the Model, hover and press are ordinary fields
        /// on the row -- so a `.list` payload would carry nothing the runtime
        /// could act on.
        ///
        /// Rows are `focusable` even though `focusStep` skips them, because a
        /// region has to EXIST before `rovingStep` can find it: `hitAppend`
        /// records one for a keyed focusable element, which is exactly what
        /// makes an arrow able to land on a row that carries no message.
        pub fn list(self: *Self, o: ListOpts) *Elem {
            const th = self.theme;
            const kids = self.alloc().alloc(*Elem, o.rows.len) catch {
                self.failWith(.layout_allocation);
                return self.column(.{ .children = &.{} });
            };
            for (o.rows, 0..) |r, i| {
                const live = o.selected != null and o.selected.? == @as(u16, @intCast(i));
                const label = self.text(.{
                    .label = r.label,
                    .size = o.size,
                    .style = .{ .fg = if (live) th.text else th.text_muted },
                });
                const item = self.row(.{
                    .children = &.{label},
                    .height = o.row_h,
                    .style = .{
                        .bg = if (live) th.selected else null,
                        .pad = o.pad,
                    },
                    .hover_bg = .{ .solid = th.hover },
                    .on_press = r.msg,
                });
                item.key = rovingKey(o.key, @intCast(i));
                item.focusable = true;
                item.disabled = r.disabled or o.disabled;
                // A disabled row is not a cursor stop: stepping onto something
                // that cannot be activated is a dead end in the middle of a
                // list, and arrows would appear to skip for no reason.
                if (!item.disabled) {
                    item.roving = o.key;
                    item.roving_index = @intCast(i);
                }
                kids[i] = item;
            }
            const root = self.column(.{
                .children = kids,
                .gap = o.gap,
                .width = o.width,
                .style = o.style,
                .margin_left = o.margin_left,
                .margin_right = o.margin_right,
                .margin_top = o.margin_top,
                .margin_bottom = o.margin_bottom,
                .disabled = o.disabled,
            });
            root.key = o.key;
            root.focusable = true;
            return root;
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

        /// Topmost interactive region under a point, with the geometry that
        /// claimed it. Same precedence as `hitTest`; capture needs the region,
        /// not just the message it would produce.
        /// Next focusable element in DOCUMENT order, for Tab traversal.
        ///
        /// The hit list is appended while the tree is walked, so ascending
        /// index IS document order. `hit()` walks it backwards because the
        /// topmost region has to win -- traversal must not reuse that order,
        /// or Tab would start at the last thing painted and run backwards.
        ///
        /// Candidates are focusable, active and keyed. Disabled elements are
        /// SKIPPED rather than focused-and-inert: landing Tab on a dead button
        /// is a dead end, and every desktop toolkit skips.
        ///
        /// A `from` that is no longer in the list -- the normal consequence of
        /// a rebuild changing what exists -- starts at the first (forward) or
        /// last (backward) candidate instead of dead-ending. Wrapping is
        /// deliberate, and a single candidate returns itself so the caller can
        /// compare and skip the repaint.
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

        /// The control payload recorded for a keyed region, valid until this
        /// frame ends. The runtime's own door: an app gets `Hit`, which never
        /// carries one. Copied out at the start of a gesture, never cached.
        pub fn widgetAt(self: *const Self, key: u64) ?*const Widget(M) {
            for (self.hits) |h| {
                if (h.key) |k| {
                    if (k == key) return h.widget;
                }
            }
            return null;
        }

        /// The scope a keyed region lives in: the innermost element that
        /// declared `focus_scope`, or null at the root.
        pub fn scopeOf(self: *const Self, key: ?u64) ?u64 {
            const k = key orelse return null;
            for (self.hits) |h| {
                if (h.key) |hk| {
                    if (hk == k) return h.scope;
                }
            }
            return null;
        }

        /// One row of a roving control, as the runtime needs it: where it is
        /// in the set, and what to focus or scroll to.
        pub const Roamer = struct { index: u16, key: u64, rect: Rect };

        /// The row `delta` places from `from_index` inside the control `owner`,
        /// clamped rather than wrapped: running off the end of a list should
        /// stop, not teleport to the other end. Rows are laid down in document
        /// order, so their `roving_index` is already ascending.
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

        /// Where an arrow key moves a roving control, given the key that
        /// currently has focus. Null when the focused element is not a row of
        /// one -- which is what lets the caller fall through to the app rather
        /// than swallowing every arrow press in the window.
        ///
        /// The caller never needs to know the owner or the row index: it has a
        /// focused key and a direction, and both live here.
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

        /// The first row (for a downward step) or the last one (for an upward
        /// step) of the roving control `owner`.
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

        /// The open popup that should take the keyboard, preferring one
        /// anchored on the focused element.
        ///
        /// Every popup is closed in the ordinary case, so this must be cheap:
        /// one pass over the hit list and a tag check. Null is the answer that
        /// makes the caller fall through to activation and then to the app.
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

        /// The highlight of a popup, and the items it highlights. Split out
        /// because both arms have to agree about which list `active` indexes.
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
        ///
        /// DERIVED, not declared: a region activates exactly when it can also
        /// be clicked and named -- a message, `focusable`, and a key. That is
        /// why a text field needs no special case to refuse Enter: it carries
        /// no message, so it is not activatable, and the key falls through to
        /// the app's `on_key`, which is the only code that knows what Enter
        /// means inside a text value. Adding a field for this would make it
        /// possible to declare a control that activates yet cannot be clicked.
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

/// Pointer capture: one press owns the click from the moment the button goes
/// down until it comes back up, so the element that was pressed is the one
/// that receives the message.
///
/// The claimed region is copied out of the frame -- `Hit` is three plain
/// fields, no pointers -- rather than borrowed from it. That matters twice:
/// a frame's arena is freed on the next repaint, and the claim has to survive
/// a repaint that reflows the content. The pressed element keeps the click
/// even if it has moved in the meantime.
pub fn Press(comptime M: type) type {
    return struct {
        const Self = @This();

        captured: ?Hit(M) = null,

        /// Claims the topmost region under the press, if any. Pressing empty
        /// space claims nothing, so releasing over a button later does not
        /// click it.
        pub fn down(self: *Self, f: *const Frame(M), p: [2]f32) void {
            self.captured = f.hit(p);
        }

        /// Releases the claim and yields the message, but only if the pointer
        /// comes up inside the region that was pressed. The release point on
        /// its own decides nothing: that is what makes pressing A and
        /// releasing over B dispatch nothing instead of B.
        pub fn up(self: *Self, p: [2]f32) ?M {
            const h = self.captured orelse return null;
            self.captured = null;
            if (!h.rect.containsRounded(h.radius, p) or !h.clip.contains(p)) return null;
            return h.msg;
        }

        /// Drops the claim without producing a message, for the paths that
        /// never see a release (window lost the pointer, app is quitting).
        /// `up` clears the claim itself.
        pub fn cancel(self: *Self) void {
            self.captured = null;
        }

        /// Re-binds a keyed claim to the element carrying the same key in a
        /// newer frame. A press that is unkeyed keeps its geometry and is
        /// untouched, so nothing that does not declare keys changes. If the
        /// keyed element is gone, the claim is dropped: releasing over
        /// whatever replaced it must not fire its message.
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
        /// Set when a primitive could not be recorded because the list could
        /// not grow. A dropped primitive is a hole in the frame -- the picture
        /// stops matching the tree that asked for it -- so `frame` reports it
        /// through the same band as a failed allocation, instead of drawing a
        /// screen that is merely missing something with no complaint.
        failed: bool = false,
        /// Where layout gets its glyph metrics. This is the renderer that will
        /// draw the frame: if it is anything else, text is measured at one
        /// width and painted at another.
        metrics: Renderer,

        pub fn renderer(self: *Self) Renderer {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        const vtable = Renderer.VTable{
            .quad = vtQuad,
            .path = vtPath,
            .rrect = vtRrect,
            .text = vtText,
            .halo = vtHalo,
            .frost = vtFrost,
            .measure_text = vtMeasure,
            .wrap_text = vtWrap,
            .advance_text = vtAdvanceText,
            .hit_text = vtHitText,
        };

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

        /// A path has no layout consequence, so the collector records nothing:
        /// it exists to account for the boxes layout produced, and a filled
        /// outline produces none. Pixel tests go through the software backend.
        fn vtPath(_: *anyopaque, _: f32, _: f32, _: Path, _: Fill, _: Rect) void {}

        fn vtQuad(ptr: *anyopaque, rect: Rect, fill: Fill, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (rect.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .quad = .{ .rect = rect, .fill = fill, .clip = clip } }) catch {
                self.failed = true;
            };
        }

        fn vtRrect(ptr: *anyopaque, rect: Rect, radius: f32, fill: Fill, stroke: bool, clip: Rect) void {
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
        fn vtText(ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Text has no rect of its own, so the prune needs the metrics that
            // will draw it. Measured twice per line overall (layout, then here)
            // and never per pixel.
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
            } }) catch {
                self.failed = true;
            };
        }

        fn vtMeasure(ptr: *anyopaque, bytes: []const u8, size: f32) TextMetrics {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.measureText(bytes, size);
        }

        fn vtWrap(ptr: *anyopaque, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.wrapText(bytes, size, max_width, out);
        }

        /// Delegate, do not reimplement: the collector records primitives but
        /// has no glyphs, and a caret placed from anything but the renderer
        /// that measures the frame would sit beside the wrong byte.
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

/// What a trimmed label ends with. Written as bytes rather than a literal so
/// the source needs no particular encoding, and because a byte count is what
/// the trimmer reasons about anyway. U+2026 HORIZONTAL ELLIPSIS.
const ellipsis: []const u8 = "\xe2\x80\xa6";

const Fitted = struct {
    bytes: []const u8,
    width: f32,
    ellipsis: bool,
};

/// The longest whole-codepoint prefix of `bytes` that fits `max_w`, keeping room
/// for the ellipsis whenever anything has to be dropped. Trimming walks back one
/// codepoint at a time so a multi-byte sequence is never cut in half -- a broken
/// UTF-8 tail paints a replacement glyph exactly where the ellipsis belongs.
/// Trailing spaces go first: "word ..." reads as a mistake.
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

/// Start of the codepoint ending at `end`. Continuation bytes are 0b10xxxxxx,
/// so walking back over them lands on a lead byte.
fn prevCodepointStart(bytes: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var i = end - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Rough metrics for tools and tests: 0.58em per glyph, no glyph data needed.
/// Never mix these with a frame that a real backend will draw — that is the
/// measure/paint divergence this module now makes impossible.
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
        .halo = nominalHalo,
        .frost = nominalFrost,
        .measure_text = nominalMeasure,
        .wrap_text = nominalWrap,
        .advance_text = nominalAdvance,
        .hit_text = nominalHit,
    } };
}

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

fn nominalPath(_: *anyopaque, _: f32, _: f32, _: Path, _: Fill, _: Rect) void {}

fn nominalQuad(_: *anyopaque, _: Rect, _: Fill, _: Rect) void {}
fn nominalRrect(_: *anyopaque, _: Rect, _: f32, _: Fill, _: bool, _: Rect) void {}
fn nominalText(_: *anyopaque, _: f32, _: f32, _: f32, _: Fill, _: []const u8, _: Rect) void {}
fn nominalHalo(_: *anyopaque, _: Rect, _: f32, _: Halo, _: Rect) void {}
// ---------------------------------------------------------------------------
// messages / runtime
// ---------------------------------------------------------------------------

/// What `update` asks the runtime to do after a message.
/// A change the app asks the runtime to make to focus. Three-state, like every
/// "unset means leave it alone" field in the library: `null` in `Action.focus`
/// keeps whatever focus there was, `.set` names a keyed element, `.clear` gives
/// focus up.
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
        /// Whether the frame clock keeps ticking. Tri-state on purpose: null
        /// leaves it as it was, so an unrelated message cannot silently stop a
        /// running animation, and `update` only has to say `true` while
        /// something is moving and `false` when it settles.
        ///
        /// This is the ONLY route by which time reaches the app. There is no
        /// clock to read in `view` -- making the tree a function of when it
        /// happened to be built would be worse than useless -- and `update`
        /// knows nothing else about the wall clock.
        animate: ?bool = null,
        /// Move focus, or give it up. Focus is RUNTIME state because the
        /// runtime is what reflects it into paint, and the app is what decides
        /// it -- so an effect is the only bridge between the two. Same shape as
        /// `quit`: something the runtime does on the app's behalf, not a
        /// message the app receives.
        ///
        /// This is what makes focus reachable from `runApp` at all. A hook gets
        /// `*Model` and `update` returns an Action; neither ever sees the
        /// runtime, so without this field the app could declare a focusable
        /// element and never focus it.
        focus: ?FocusChange = null,
        /// Move a viewport's offset. Same reasoning as `focus`: the offset is
        /// runtime state, so the app can ask for a change but cannot write the
        /// number in `view` -- the runtime injects it between `view` and
        /// layout, so an app that set it there would be overwritten every
        /// frame. This is the channel for "show me the top" and "reveal the
        /// row I just added"; the wheel and the thumb do not come through here.
        scroll: ?ScrollChange = null,
        /// Put these bytes on the clipboard. An EFFECT, like `focus` and
        /// `scroll`, because the app can ask but cannot do it: `view` has no
        /// platform, and `Cmd` runs off-thread and returns a ?M rather than a
        /// side effect. There is no `cut` variant -- a cut is a copy plus the
        /// app deleting from its own Model, which only it can do anyway, and a
        /// field that changed nothing would be a lie in the type.
        ///
        /// The bytes are arena-lived: valid until the frame ends. A caller that
        /// keeps them past `update` must own them.
        clipboard: ?[]const u8 = null,

        pub fn then(c: Cmd(M)) @This() {
            return .{ .cmd = c };
        }
    };
}

/// A job that runs on a worker thread and produces at most one message.
///
/// `ctx` must outlive the job (the runtime joins its workers on deinit).
pub fn Cmd(comptime M: type) type {
    return struct {
        ctx: *const anyopaque,
        run: *const fn (ctx: *const anyopaque) ?M,
    };
}

/// Zig 0.16 moved the blocking mutex to `std.Io.Mutex`, which needs an `Io` to
/// lock. The executor's critical sections are two or three instructions, so a
/// spinlock avoids threading an `Io` through the runtime for no benefit.
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
/// Messages are queued under a mutex; the UI thread drains them and dispatches.
pub fn Executor(comptime M: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        mutex: Spin = .{},
        done: std.ArrayList(M) = .empty,
        /// One entry per command whose worker may still be running. The
        /// completion flag is per-command, so `reap` can tell which handles are
        /// joinable WITHOUT waiting for the whole executor to go idle. Waiting
        /// on `outstanding == 0` bounded the list between bursts but not during
        /// one: an app that always had a command in flight never reaped at all.
        handles: std.ArrayList(Handle) = .empty,
        outstanding: usize = 0, // guarded by mutex
        lost: usize = 0, // guarded by mutex
        /// How many commands may hold a thread at once. A screen that fires a
        /// command per row would otherwise be a thread per row. There is no
        /// idle pool because a worker waiting for work needs a BLOCKING wait,
        /// and 0.16 keeps those on `std.Io`, which this type deliberately has
        /// none of -- so a worker that finds the queue empty exits instead.
        max_running: usize = 8,
        running: usize = 0, // guarded by mutex
        /// Commands over the cap, waiting for a worker to take one.
        pending: std.ArrayList(Cmd(M)) = .empty, // guarded by mutex

        /// Per-command completion, heap-owned so its address is stable: the
        /// handle list can reallocate while a worker is still writing to this,
        /// which is why the flag does not live inside `Handle`.
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

        /// Give back a slot that never became a thread. It is not in flight, so
        /// it must not keep `busy()` true, and the app will never hear from it.
        fn failStart(self: *Self) void {
            self.mutex.lock();
            self.running -= 1;
            self.outstanding -= 1;
            self.lost += 1;
            self.mutex.unlock();
        }

        /// Queue a completed message. The CALLER holds the mutex.
        ///
        /// A result that cannot be queued is the same outcome as a command that
        /// never started: the app waits for a message that will not arrive, and
        /// cannot tell that from slow work. It is counted in `lost` for exactly
        /// that reason rather than dropped.
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

        /// Commands that could not be started. A command that never runs is a
        /// message that never arrives, so the app waits for a result it cannot
        /// distinguish from slow work -- this count is the only way to see it.
        pub fn lostCommands(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.lost;
        }

        /// Join workers that have finished, so `handles` stays bounded by the
        /// commands IN FLIGHT rather than growing for the life of the app.
        /// Per-command flags mean this does not wait for the executor to go
        /// idle: a burst of fast commands is reaped while a slow one runs on.
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

        /// True while workers are still running (cheap hint for the loop: it
        /// should poll with a short timeout instead of blocking forever).
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

/// Which modifier keys were held when a key event was produced.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false,
};

/// Keys worth naming, because binding to a raw code is how you get a shortcut
/// that quietly stops working on another layout. This is a convenience list,
/// not a filter: anything absent still arrives, in `Key.code`.
pub const Named = enum {
    enter,
    escape,
    tab,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// One key, described three ways because the three are not interchangeable.
///
/// `code` is the layout-dependent symbol -- what the key is LABELLED, and what
/// a shortcut wants: on Dvorak the physical C position produces 'j', and
/// Ctrl+Z means the label. `scancode` is physical POSITION, which is what
/// W-A-S-D movement wants so it stays put across layouts. `named` is the
/// common subset of both, so `update` does not compare magic numbers.
///
/// Typed text does NOT come from here. A dead-key accent, a compose sequence
/// or an IME commit has no single key to derive from, so text arrives as its
/// own event once a text field exists. A Ctrl chord produces no text at all --
/// that asymmetry is why both paths are needed rather than one.
///
/// All three are u32 (SDL's keycode, SDL's scancode, xkbcommon's keysym).
/// Narrowing this to u8 was not a simplification: SDLK_LEFT is 0x40000050, and
/// truncating it yields the character 'P'.
pub const Key = struct {
    named: ?Named = null,
    code: u32 = 0,
    scancode: u32 = 0,
    mods: Mods = .{},
    /// True for the extra presses a backend synthesises while the key is held.
    /// A flag rather than its own event type because the app cannot tell -- and
    /// must not care -- whether the platform or the runner timed the repeat.
    /// Wayland has no server-side repeat, so that answer does change per
    /// backend; a flag keeps it from leaking into every `update`.
    repeat: bool = false,
};

/// How a shortcut names its key.
///
/// Two spellings because they answer different questions. `ch` is the LABEL --
/// what Ctrl+S means, which on Dvorak is the key that types `o` -- and `named`
/// is the common set of named keys. A raw `code` is deliberately NOT bindable:
/// a shortcut bound to a physical position is the one that stops working the
/// day somebody switches layout.
pub const ShortcutKey = union(enum) {
    ch: u8,
    named: Named,

    /// So a call site reads `.key = ShortcutKey.char('s')`.
    pub fn char(c: u8) ShortcutKey {
        return .{ .ch = c };
    }
};

/// One binding. Declared on the app, comptime, so a collision is a build error.
pub fn Shortcut(comptime M: type) type {
    return struct {
        key: ShortcutKey,
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
        gui: bool = false,
        msg: M,
    };
}

/// Whether `k` is exactly the chord `sc` names.
///
/// Every modifier must match, including the absent ones: Ctrl+Shift+S is not
/// Ctrl+S, and a rule that ignored `shift` would make the two impossible to
/// tell apart. Pure, so the matching rule is testable without a window, a
/// runner or a frame.
pub fn shortcutMatches(sc: anytype, k: Key) bool {
    if (k.mods.ctrl != sc.ctrl) return false;
    if (k.mods.shift != sc.shift) return false;
    if (k.mods.alt != sc.alt) return false;
    if (k.mods.gui != sc.gui) return false;
    return switch (sc.key) {
        .ch => |c| blk: {
            if (k.code > 127) break :blk false;
            break :blk std.ascii.toLower(@as(u8, @intCast(k.code))) == std.ascii.toLower(c);
        },
        .named => |n| k.named == n,
    };
}

/// A binding with no command modifier is BARE: it types a character.
///
/// Shift does not count as a modifier here, because Shift+S is how a capital S
/// is typed -- treating it as a chord would make "select all" fire on a
/// keystroke someone meant as a letter.
pub fn isBareShortcut(sc: anytype) bool {
    return !sc.ctrl and !sc.alt and !sc.gui;
}

/// The message `k` should dispatch, or null when no binding claims it.
///
/// Bare bindings are skipped while a text field has focus, or every letter
/// typed into it would also run a command.
pub fn shortcutFor(comptime M: type, comptime list: anytype, k: Key, text_editing: bool) ?M {
    inline for (list) |sc| {
        // One combined condition rather than two `continue`s: `continue` inside
        // `inline for` is comptime control flow and does not belong in a
        // function the runtime calls.
        if (shortcutMatches(sc, k) and !(text_editing and isBareShortcut(sc))) {
            return sc.msg;
        }
    }
    return null;
}

/// Comptime guard: two commands on one chord is a build error, never a race
/// decided by whichever arm was written first.
pub fn checkShortcuts(comptime list: anytype) void {
    comptime {
        for (0..list.len) |i| {
            for (i + 1..list.len) |j| {
                const a = list[i];
                const b = list[j];
                if (a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and
                    a.gui == b.gui and std.meta.eql(a.key, b.key))
                {
                    @compileError("two shortcuts are bound to the same chord");
                }
            }
        }
    }
}

/// Scroll wheel movement, in the platform's own units.
///
/// The deltas are NOT normalised. A notched wheel reports whole steps, a
/// trackpad reports fractions per event, and the backend has already applied
/// the user's scroll-speed setting. Dividing by a magic number so the two
/// "compare" is how a library ends up scrolling at a different speed than
/// every native app on the same machine.
///
/// `x`/`y` are the pointer at the time of the event: scroll has a target even
/// though it is not a click, and the target is whatever is under the cursor.
pub const Wheel = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

pub const Event = union(enum) {
    /// window wants to close; the runner stops.
    quit,
    /// The window's size changed, so the next frame must be built for a
    /// different box. Deliberately carries NO payload: the backend has already
    /// adopted the new size, so `Window.size()` is the answer and a number
    /// carried here could only be a stale copy of it -- two sizes that disagree
    /// is exactly the bug that made resizing draw one layout while the pointer
    /// was tested against another.
    resize,
    pointer_down: [2]f32,
    pointer_up: [2]f32,
    pointer_move: [2]f32,
    /// The gesture ended without a release we will ever see: focus taken away,
    /// or the pointer left the window mid-drag. Without this the press claim
    /// outlives the gesture and the pressed element stays lit forever.
    pointer_cancel,
    key: Key,
    /// The release matching one `key`. Never repeats.
    key_up: Key,
    /// Text the user actually typed, as UTF-8 bytes.
    ///
    /// This is NOT derivable from `Key`, which is why it is its own event: a
    /// dead key, a compose sequence or an IME commit produces text with no
    /// single key to blame, and a Ctrl chord produces none at all. Reading
    /// `Key.code` and calling it a character is how a text field ends up
    /// wrong on every layout but QWERTY.
    ///
    /// The bytes are BORROWED from the backend and are only valid until the
    /// dispatch that carries them returns. Copy anything kept past `update`.
    text: []const u8,
    /// Wheel movement. Deliberately its own event rather than a field on
    /// `pointer_move`: a wheel event that reports no movement is normal, and
    /// folding it into motion would make every scroll look like the pointer
    /// jumped.
    wheel: Wheel,
};

/// Which half of a keystroke an `on_key` hook is being told about. `repeat`
/// lives on `Key`, not here: a repeat is still a press.
pub const Phase = enum { down, up };

/// What the platform has told us about the pointer. Nothing here says who
/// owns a press: that lives in `Press`, and giving it a second home is how
/// the two copies start disagreeing.
pub const Pointer = struct {
    /// last known position, if the backend has ever reported one
    pos: ?[2]f32 = null,
};

/// What paint needs: the position, and the rect that owns the press in
/// flight. Derived in `Runtime.frame()` from `Runtime.press`, never stored
/// beside it. A press in flight suppresses hover everywhere, so dragging off
/// a button leaves that button pressed and does not light up the one under
/// the cursor.
pub const PointerView = struct {
    pos: ?[2]f32 = null,
    /// geometry of the region that owns the press, compared by identity
    held: ?Region = null,
};

/// What a paint pass knows about hover. Pass one fills `out` with every region
/// that could show hover feedback; pass two is handed the one region that was
/// resolved from it, so the innermost element is the only one that lights up.
const Hover = struct {
    out: ?*std.ArrayList(Region) = null,
    target: ?Region = null,
    /// Which key the runtime considers focused. Focus is DERIVED in paint, the
    /// same way hover is: the runtime says which identity holds focus, and each
    /// element decides whether that is it. Nothing is written back.
    focus: ?u64 = null,
};

/// The platform layer, expressed in elmz terms only. A backend (SDL3, Wayland
/// shm, X11, a test harness) implements this; nothing above this line knows
/// which one is in use, and no backend may leak its own types upward.
pub const Window = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Next event, blocking up to `timeout_ms` (-1 = forever). null = timeout.
        poll: *const fn (ptr: *anyopaque, timeout_ms: i32) ?Event,
        /// Hand a finished RGBA frame to the screen. `pixel_size` is the size of
        /// that buffer in DEVICE pixels -- not the logical window size, which is
        /// what a texture allocated at logical size would be the wrong size for.
        present: *const fn (ptr: *anyopaque, pixels: []const u8, pixel_size: Size) void,
        /// Logical window size, in the same units events are reported in.
        size: *const fn (ptr: *anyopaque) Size,
        /// Device pixels per logical unit; 1.0 is unscaled.
        ///
        /// This is the only quantity above the renderer that is not logical, and
        /// it exists for exactly one reason: the canvas has to be allocated in
        /// device pixels. Nothing else above the renderer should read it.
        density: *const fn (ptr: *anyopaque) f32,
        deinit: *const fn (ptr: *anyopaque) void,
        /// Clipboard text, for PASTE. Borrowed, valid until the next call, so
        /// a caller that keeps it must copy it -- the same contract as
        /// `Event.text`. Optional because a headless backend has no clipboard
        /// and null is the honest answer.
        ///
        /// This cannot arrive as `Event.text`: a Ctrl chord produces no text
        /// event, and no platform synthesises a paste. So the runtime reads the
        /// clipboard itself, at the one point it sees the key first.
        clipboard_text: ?*const fn (ptr: *anyopaque) ?[]const u8 = null,
        /// Put text on the clipboard: the outbound half of the same seam.
        /// Optional for the same reason.
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
        updateFn: *const fn (*S, M) Action(M),
        viewFn: *const fn (*S, *UiT) *Elem,
        ui: UiT,
        exec: ?Executor(M) = null,
        /// last position the platform reported
        pointer: Pointer = .{},
        /// The press in flight, if any. This is the only owner of "who owns
        /// the click": the hover suppression and the pressed colour are both
        /// derived from it when a frame is built, never stored beside it. The
        /// press belongs to the region it started on, not to wherever the
        /// pointer happens to be when the button comes back up.
        press: Press(M) = .{},
        /// Which keyed element currently holds focus, or null for none. The app
        /// DECIDES this (it sets the field from its own Msg handlers); the
        /// runtime only reflects it into the paint pass. Deliberately a bare
        /// `?u64` rather than a focus ring with a destination, so the tree stays
        /// a value and no widget needs a closure to ask "am I focused".
        focus: ?u64 = null,
        /// Seconds since the runtime started, accumulated from the RAW clock
        /// delta rather than the clamped `dt` given to `on_tick`: the clamp
        /// exists so a stall cannot teleport an animation, and freezing a blink
        /// for the same stall would be the worse of the two failures.
        elapsed: f32 = 0,
        /// Seconds since the last key or text event. The runner resets it and
        /// mirrors it into `Ui`; nothing else writes it.
        since_input: f32 = 0,
        /// How long the pointer has rested on the current region, reset when
        /// it moves to a different one. The tooltip delay and nothing else:
        /// `elapsed` says how long the app has run, not how long you have been
        /// looking at that particular thing.
        hover_since: f32 = 0,
        /// Whether a text-input widget holds focus, which is what suppresses
        /// bare-key shortcuts -- an unmodified `s` must type an `s`, not fire
        /// a command. Nothing sets it yet: there is no text input. The field
        /// exists so that widget has somewhere to say so, rather than the rule
        /// arriving later as a second mechanism.
        text_editing: bool = false,
        /// The window, when there is one. Held ONLY for outbound effects the
        /// runtime applies on the app's behalf -- today that is the clipboard
        /// -- because `dispatch` is the single funnel for those and it has no
        /// other route to the platform. Null in tests, which is what keeps a
        /// clipboard write headlessly observable.
        window: ?Window = null,
        /// Optional keystroke hooks, wired by `runApp` from the app declaration.
        ///
        /// The app owns FOCUS -- which element a keystroke belongs to -- because
        /// focus is widget state, and widget state lives in the Model until it
        /// hurts. The runtime has no focus ring to consult, so it cannot pick a
        /// destination, and inventing one would mean putting a closure on
        /// `Element`, which the tree deliberately does not carry: a button
        /// carries a Msg so the whole tree stays a value.
        ///
        /// Returning null means "not mine": no message and NO repaint. That is
        /// what keeps a keystroke nobody wants from forcing a frame.
        on_key: ?*const fn (*S, Key, Phase) ?M = null,
        /// Same contract for typed text; see `Event.text` for why it is not
        /// derivable from keys and why the slice is borrowed.
        on_text: ?*const fn (*S, []const u8) ?M = null,
        /// Scroll wheel, delivered raw and unclassified. Which container the
        /// deltas apply to is the APP's business until there is a scroll
        /// container: the offset has to live in the Model, because `view` must
        /// read it to clip and translate, and the runtime cannot hold state
        /// `view` needs privately the way it does with hover.
        on_wheel: ?*const fn (*S, Wheel) ?M = null,
        /// A press that landed on NO region at all: no control, no thumb, no
        /// viewport. It is the one press nothing can claim, so without this a
        /// popup has no way to hear the click that should dismiss it. The
        /// position is handed over because it is already in hand.
        ///
        /// It is deliberately NOT "the user clicked outside my panel": a click
        /// on another control claims that control and never reaches here. For
        /// that case an overlay with a full-size child is the mechanism -- it
        /// claims everything, and its children paint (and hit) above it.
        on_outside: ?*const fn (*S, [2]f32) ?M = null,
        /// Frame clock: seconds since the previous tick, called at the top of
        /// every loop iteration while the app is animating. Clamped by the
        /// runner so a window that sat idle for a minute does not arrive as
        /// one enormous step.
        on_tick: ?*const fn (*S, f32) ?M = null,
        /// True while the app wants frames without input. Lives here because
        /// the loop consults it BEFORE it decides how long to block in poll.
        animate: bool = false,
        /// Offsets for keyed scroll viewports. Fixed capacity, drop-oldest:
        /// an allocator for this would be state that can fail mid-frame, and a
        /// viewport that left the tree is not worth remembering anyway.
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

        /// Messages produced by commands since the last call. Dispatch them
        /// from the UI thread; they are ordinary messages.
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
        ///
        /// Offset from the runtime's own store, which exists whether or not a
        /// frame is being built. `scrollAt` answers the same question from the
        /// copy the current frame handed to `view`.
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

        /// Set a viewport's offset outright. The wheel clamps before calling
        /// this, because the content extent is only known to the frame it just
        /// came from; paint clamps again on read, which is what makes a stored
        /// value that is one frame stale harmless.
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

        /// Move a viewport. Clamping to the content extent happens at paint,
        /// where the content height is known, so an offset past the end here
        /// is the store being one frame ahead -- not a bug to fix twice.
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

        /// Push the store into the tree. The offset is runtime state, so it
        /// cannot be written in `view` -- an app that set it there would be
        /// overwritten every frame. Same shape as `disabled` inheritance.
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
            const tag = std.meta.activeTag(e.geometry);
            switch (tag) {
                .column, .row, .stack, .scroll => {
                    e.scroll_key = path;
                    e.scroll_offset = self.scrollAtKey(path);
                    e.scroll_offset_x = self.scrollAtKeyX(path);
                },
                .text, .button, .bar, .rect => {},
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
                .text, .button, .bar, .rect => {},
            }
        }

        /// `metrics` is the renderer that will draw this frame, normally
        /// `canvas.renderer()`. It is not optional on purpose: layout and
        /// rasterisation must agree on glyph widths, and the only way to
        /// guarantee that is to measure with the thing that paints.
        ///
        /// The returned frame owns its data (including text bytes) and stays
        /// valid until `deinit()`, even across later `frame()` calls.
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
                }
            }

            try root.paint(r, root_rect, Rect.unbounded, view, &hits, a, .{ .target = resolved, .focus = self.focus }, self.ui.theme);

            // Keys are identity, and identity that collides is worse than no
            // identity: `rebind` would bind a press to whichever twin it met
            // first. So it is a bug -- but not one worth taking the app down
            // for. It is reported the same way a failed allocation is, through
            // the band, which keeps the frame usable and names the fault.
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
        ui.textFmt("{d}", .{s.n}, 20),
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

/// Fails exactly ONE allocation, then behaves normally.
///
/// std.testing.FailingAllocator is permanent: once it trips, every later
/// allocation fails too. That makes the error band impossible to observe --
/// with the allocator dead, the collector cannot record the very prims the
/// band is made of, so `failed` can be true in a frame that renders nothing.
/// Real out-of-memory is rarely total; a single oversized request failing
/// while the rest succeed is exactly the case the band exists for, and this
/// reproduces it.
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
    for (kids[0..n], 0..) |*k, i| k.* = ui.textFmt("{d}", .{i}, 12);
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
    const box = ui.rect(.{ .width = 80, .height = 40, .style = .{ .bg = ui.theme.panel, .bg_grad = Fill.vgrad(ui.theme.accent, ui.theme.bg), .border = ui.theme.border, .border_grad = Fill.hgrad(ui.theme.accent, ui.theme.text_muted) } });
    const label = ui.text(.{ .label = "grad", .size = 12, .style = .{ .fg_grad = Fill.hgrad(ui.theme.accent, ui.theme.text_muted) } });
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

    var f = try rt.frame(.{ .w = 300, .h = 120 }, nominalRenderer());
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

test "every Style field is honoured by applyStyle and mergeStyle" {
    // A field-by-field merge is a list that a new field can be left off, and
    // the omission is invisible: the element simply keeps its default and
    // nothing reports it. `halo` was dropped exactly that way -- a card asked
    // for a shadow, the frame said "0 halo(s)", and no test complained.
    // Iterating the fields makes the next one fail to compile instead.
    const S = Style;
    var full: S = .{};
    inline for (@typeInfo(S).@"struct".fields) |f| {
        const Child = @typeInfo(f.type).optional.child;
        const v: f.type = switch (Child) {
            Color => .{ .r = 1, .g = 2, .b = 3, .a = 4 },
            Fill => .{ .solid = .{ .r = 5, .g = 6, .b = 7, .a = 8 } },
            f32 => 7,
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
        if (@typeInfo(f.type).optional.child == f32) {
            // applyStyle defaults an absent radius/pad, so compare as optional
            try std.testing.expect(@field(a, f.name) == @field(full, f.name).?);
        } else {
            try std.testing.expect(std.meta.eql(@field(a, f.name), @field(full, f.name).?));
        }
    }

    // mergeStyle: only the fields the caller set, all of which are set here
    var m: Element(void) = .{ .geometry = .{ .rect = {} } };
    m.mergeStyle(full);
    inline for (@typeInfo(S).@"struct".fields) |f| {
        if (@typeInfo(f.type).optional.child == f32) {
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

/// One button, optionally keyed. `focusable` without a key is the case that
/// matters: focus names an identity, so an anonymous element cannot hold it.
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

/// How many prims are filled with exactly `c`. A colour reaching paint is the
/// only proof a mapping is not crossed: a builder can name the right role and
/// still hand back the neighbouring one, and a severity that paints in the
/// warning colour is a defect no payload assertion would notice.
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

/// Ten 20px rows in a 100px viewport: 200 of content, 100 of view, so the
/// maximum offset is exactly 100 and every row is 20 below the one before it.
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

/// The viewport's scroll identity: the column the view builds sits at child 0
/// of the root, so its identity is one step down the root path. NOTHING in the
/// app supplies this -- that is the whole point of implicit scrolling.
fn vpKey() u64 {
    return pathChild(scroll_path_root, 0);
}

/// The stack-wrapped view adds one level: stack -> column -> column.
/// Identity is a tree path, so deeper nesting means a deeper key.
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

/// The same viewport, nested inside a stack.
///
/// A container geometry added after the scroll work has to be walked by
/// `injectScrollOffsets` too. The switch ends in an else-branch, so a geometry
/// nobody listed is not an error -- it is a subtree that silently never
/// receives its offset, and a viewport that renders with a thumb that is
/// there, correctly sized, and inert.
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

/// Document order 1, 2, 3, with 2 optionally disabled, bracketed by one
/// focusable element that has no key and one that is not focusable at all.
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
    unkeyed.focusable = true; // focusable but unnamed, so it cannot be landed on
    c.focusable = true;
    return ui.column(.{ .children = &.{ a, b, unkeyed, not_focusable, c } });
}

test "tab walks document order, skips a disabled control, and wraps" {
    const gpa = std.testing.allocator;
    var rt = Runtime(TabState, TabMsg).init(gpa, .{}, tabUpdate, tabView);
    defer rt.deinit();

    rt.state.disable_mid = true;
    {
        var f = try rt.frame(.{ .w = 200, .h = 300 }, nominalRenderer());
        defer f.deinit();

        // Ascending index is document order, not the reverse order hit() uses.
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(null, true));
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(1, true));
        try std.testing.expectEqual(@as(?u64, 1), f.focusStep(3, true));

        // Backwards from nowhere starts at the last candidate.
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(null, false));
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(1, false));

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
        try std.testing.expectEqual(@as(?u64, 2), f.focusStep(1, true));
        try std.testing.expectEqual(@as(?u64, 3), f.focusStep(2, true));
        try std.testing.expectEqual(@as(?u64, 2), f.focusStep(3, false));
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

/// The y of the first text prim carrying exactly `bytes`. Text has no rect of
/// its own, so a baseline test has to read the glyph origin itself.
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

/// A disabled slider and a disabled select: both must stay inert, which for a
/// widget means "cannot be dragged and cannot be opened" -- not merely "has no
/// message", since a slider dispatches on a DRAG and a select on the popup.
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

/// A roving control (key 30) with three rows (40, 41, 42), then a control that
/// follows it (50).
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
            var guard: usize = 0;
            while (!release.load(.acquire) and guard < 4_000_000) : (guard += 1) {
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
    try std.testing.expectEqual(@as(usize, 0), countSolidPrims(f.prims, th.@"error"));
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
