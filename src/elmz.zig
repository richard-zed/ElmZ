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

    pub fn rgbHex(hex: u32) Color {
        return .{
            .r = @intCast((hex >> 16) & 0xff),
            .g = @intCast((hex >> 8) & 0xff),
            .b = @intCast(hex & 0xff),
        };
    }
};

pub const Size = struct { w: f32 = 0, h: f32 = 0 };

// ---------------------------------------------------------------------------
// paint: a solid colour is one case of a fill, not the whole type
// ---------------------------------------------------------------------------

/// One colour of a gradient, at position `at` in 0..1 along the axis.
pub const Stop = struct {
    at: f32 = 0,
    color: Color = .{ .r = 0, .g = 0, .b = 0 },
};

/// Gradient stops, stored inline, four at most. A slice would be smaller on
/// the wire and is the obvious shape -- but a gradient is built inside `view`
/// and rasterised *after* `view` returns, so a slice would point at a dead
/// stack frame. Value semantics cost 36 bytes and delete the whole question.
pub const Stops = struct {
    n: u8 = 0,
    items: [4]Stop = @splat(.{}),

    pub fn two(a: Color, b: Color) Stops {
        return .{ .n = 2, .items = .{ .{ .at = 0, .color = a }, .{ .at = 1, .color = b }, .{}, .{} } };
    }

    pub fn three(a: Color, b: Color, c: Color) Stops {
        return .{ .n = 3, .items = .{
            .{ .at = 0, .color = a }, .{ .at = 0.5, .color = b }, .{ .at = 1, .color = c }, .{},
        } };
    }

    pub fn four(a: Color, b: Color, c: Color, d: Color) Stops {
        return .{ .n = 4, .items = .{
            .{ .at = 0, .color = a },     .{ .at = 0.333, .color = b },
            .{ .at = 0.667, .color = c }, .{ .at = 1, .color = d },
        } };
    }

    /// Sample at `t`. Flat outside the end stops (every toolkit does this), so
    /// a rect taller than its axis does not snap to an edge colour.
    pub fn at(self: Stops, t: f32) Color {
        if (self.n == 0) return .{ .r = 0, .g = 0, .b = 0 };
        if (t <= self.items[0].at) return self.items[0].color;
        var i: usize = 1;
        while (i < self.n) : (i += 1) {
            const b = self.items[i];
            if (t <= b.at) {
                const a = self.items[i - 1];
                const span = b.at - a.at;
                return mix(a.color, b.color, if (span <= 0) 1 else (t - a.at) / span);
            }
        }
        return self.items[self.n - 1].color;
    }

    /// Interpolate in PREMULTIPLIED space. A straight rgb lerp toward a
    /// transparent colour drags the midpoint toward black -- the classic muddy
    /// fade. Costs one divide per sampled pixel.
    fn mix(a: Color, b: Color, u: f32) Color {
        const t = std.math.clamp(u, 0, 1);
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

    /// Vertical, top to bottom.
    pub fn vgrad(a: Color, b: Color) Fill {
        return .{ .linear = .{ .stops = Stops.two(a, b) } };
    }

    /// Horizontal, left to right.
    pub fn hgrad(a: Color, b: Color) Fill {
        return .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 0 }, .stops = Stops.two(a, b) } };
    }

    /// Diagonal, corner to corner.
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
    /// false = present but inert: it still occludes what is behind it, and it
    /// never becomes a hover or press candidate. A disabled control that
    /// simply vanished from the list would let clicks through to whatever it
    /// covers, which is the wrong meaning of "disabled".
    active: bool = true,

    pub fn eql(self: Region, rect: Rect, clip: Rect) bool {
        return self.rect.eql(rect) and self.clip.eql(clip);
    }

    pub fn holds(self: Region, p: [2]f32) bool {
        return self.rect.contains(p) and self.clip.contains(p);
    }
};

/// Renderer-agnostic draw commands. A backend either rasterises these directly
/// (software) or feeds them to a GPU pipeline (triangles + glyph quads).
pub const Primitive = union(enum) {
    quad: struct { rect: Rect, fill: Fill, clip: Rect },
    /// rounded rect: `stroke` draws a 1px outline instead of a fill
    rrect: struct { rect: Rect, radius: f32, fill: Fill, stroke: bool, clip: Rect },
    text: struct { x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect },

    /// `clip` is repeated in each prong because a Zig union has no common
    /// fields. It is the scissor rect resolved at record time, so a primitive
    /// is self-contained: replaying it needs no stack and no ordering.
    pub fn clipOf(self: Primitive) Rect {
        return switch (self) {
            .quad => |q| q.clip,
            .rrect => |q| q.clip,
            .text => |t| t.clip,
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

    pub const VTable = struct {
        quad: *const fn (ptr: *anyopaque, rect: Rect, fill: Fill, clip: Rect) void,
        /// draws a rounded rect, or its 1px outline when `stroke` is set
        rrect: *const fn (ptr: *anyopaque, rect: Rect, radius: f32, fill: Fill, stroke: bool, clip: Rect) void,
        text: *const fn (ptr: *anyopaque, x: f32, y: f32, size: f32, fill: Fill, bytes: []const u8, clip: Rect) void,
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

    pub fn measureText(self: Renderer, bytes: []const u8, size: f32) TextMetrics {
        return self.vtable.measure_text(self.ptr, bytes, size);
    }

    pub fn wrapText(self: Renderer, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
        return self.vtable.wrap_text(self.ptr, bytes, size, max_width, out);
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
pub const ThemeFileType = theme.ThemeFileType;
pub const Loaded = theme.Loaded;
pub const ThemeDiag = theme.ThemeDiag;
pub const ThemeLoadError = theme.ThemeLoadError;
pub const theme_version = theme.theme_version;
pub const defaults_zon = theme.defaults_zon;
pub const loadTheme = theme.loadTheme;
pub const defaultTheme = theme.defaultTheme;
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
        };
    }
};

pub fn Hit(comptime M: type) type {
    return struct {
        rect: Rect,
        clip: Rect,
        msg: M,
        /// Identity of the element that produced this region, if it declared
        /// one. A keyed press re-binds to the element carrying the same key
        /// instead of to a rectangle, so it survives the content reordering
        /// around it. Sibling keys must be unique; nothing enforces that yet.
        key: ?u64 = null,
        /// mirrors the element's `disabled`: recorded so a press can be
        /// cancelled when the element it claimed turns inert mid-gesture.
        active: bool = true,
    };
}

/// Enqueues a hit region clipped to what is actually visible. A fully clipped
/// element is not pressable, so `Frame.hitTest` stays a plain `contains` loop
/// with no clip logic of its own.
fn hitAppend(
    comptime M: type,
    hits: *std.ArrayList(Hit(M)),
    gpa: Allocator,
    rect: Rect,
    clip: Rect,
    msg: M,
    key: ?u64,
    active: bool,
) Allocator.Error!void {
    if (rect.intersect(clip).isEmpty()) return;
    // A disabled element is not pressable, so it never enters the hit list:
    // suppression happens at registration, not at dispatch, which keeps
    // `Frame.hit` a plain contains loop and means `press.down` cannot claim
    // something that refuses input.
    try hits.append(gpa, .{ .rect = rect, .clip = clip, .msg = msg, .key = key, .active = active });
}

pub fn Element(comptime M: type) type {
    return struct {
        const Self = @This();

        kind: Kind,
        /// inner padding for containers
        pad: f32 = 0,
        /// gap between children, uniform by definition
        gap: f32 = 0,
        /// spacing added immediately BEFORE this child, on top of the
        /// container's `gap`. This is how uneven spacing is expressed: as a
        /// number on the child, not as a phantom spacer element in the child
        /// list. Nothing in layout walks a child that draws nothing.
        space_before: f32 = 0,
        /// spacing added AFTER this child, for trailing space.
        space_after: f32 = 0,
        /// overrides the measured width (useful inside rows)
        width: ?f32 = null,
        height: ?f32 = null,
        /// fills this element's rect before anything inside it is painted
        bg: ?Color = null,
        /// gradient override for `bg`; wins over the flat colour when set
        bg_grad: ?Fill = null,
        /// what this element draws with on top of `bg`: text colour, control
        /// label, bar fill. Appearance lives on the element rather than inside
        /// `Kind` so a kind describes structure only — which is what lets a
        /// widget take its colours from the theme instead of needing a variant
        /// per look.
        fg: ?Color = null,
        fg_grad: ?Fill = null,
        /// 1px inset outline, drawn inside the rect so it costs no layout
        border: ?Color = null,
        border_grad: ?Fill = null,
        /// wrap text to the width layout gives this element
        wrap: bool = false,
        /// corner rounding; 0 = square. Clamped to half the shorter side.
        radius: f32 = 0,
        /// makes any element pressable, not just buttons
        on_press: ?M = null,
        /// confine every descendant to this element's rect (rect clip only;
        /// rounded corners are not cut yet). Off by default, so nothing that
        /// does not ask for it changes.
        clips: bool = false,
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
        /// identity for keyed children. When set, a press that starts here
        /// re-binds to the element carrying the same key on later frames
        /// rather than to a rectangle, so it survives reordering. Unique among
        /// siblings; unset means the old rect-based behaviour.
        key: ?u64 = null,

        pub const Kind = union(enum) {
            column: struct { children: []const *Self },
            row: struct { children: []const *Self },
            text: struct { bytes: []const u8, size: f32 },
            button: struct { label: []const u8, size: f32 },
            bar: struct { value: f32 },
            /// a plain sized box; the only kind with no intrinsic size
            rect: void,
        };

        /// Height (and resolved width) at `avail_w` — the width the parent is
        /// about to give this element.
        ///
        /// `avail_w` exists so wrapping does not have to be told its width by
        /// the call site, where the number is a guess that layout has not
        /// computed yet. It is the same number paint lays the element out
        /// with, which is what keeps measure and paint breaking lines in the
        /// same place.
        /// The appearance actually painted for a slot. The gradient override
        /// wins over the flat colour, because a caller who set a gradient
        /// meant it; `fallback` is what the kind or theme defaults to.
        fn pick(solid: ?Color, grad: ?Fill, fallback: ?Fill) ?Fill {
            if (grad) |g| return g;
            if (solid) |c| return .{ .solid = c };
            return fallback;
        }

        pub fn measure(self: *const Self, r: Renderer, avail_w: f32) Size {
            var s: Size = switch (self.kind) {
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
                        };
                    }
                    // `pad` grows the box on every kind, so a filled text
                    // element is a chip and not a label with its edges shaved.
                    break :blk .{ .w = ts.width + 2 * self.pad, .h = ts.height + 2 * self.pad };
                },
                .button => |b| blk: {
                    const ts = r.measureText(b.label, b.size);
                    break :blk .{ .w = ts.width + 24, .h = ts.height + 16 };
                },
                .bar => .{ .w = 0, .h = 10 },
                .rect => .{ .w = 0, .h = 0 },
                .column => |c| blk: {
                    const inner_avail = (self.width orelse avail_w) - 2 * self.pad;
                    var w: f32 = 0;
                    var h: f32 = 0;
                    for (c.children, 0..) |ch, i| {
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, inner_avail);
                        w = @max(w, cs.w);
                        if (i > 0) h += self.gap;
                        h += ch.space_before;
                        h += cs.h;
                        h += ch.space_after;
                    }
                    break :blk .{ .w = w + 2 * self.pad, .h = h + 2 * self.pad };
                },
                .row => |c| blk: {
                    var w: f32 = 0;
                    var h: f32 = 0;
                    for (c.children, 0..) |ch, i| {
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, avail_w);
                        h = @max(h, cs.h);
                        if (i > 0) w += self.gap;
                        w += ch.space_before;
                        w += ch.width orelse cs.w;
                        w += ch.space_after;
                    }
                    break :blk .{ .w = w + 2 * self.pad, .h = h + 2 * self.pad };
                },
            };
            if (self.width) |w| s.w = w;
            if (self.height) |h| s.h = h;
            return s;
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

            // Derived appearance. A press in flight beats hover, and it beats
            // it everywhere: while one element owns the press, nothing else
            // lights up. That is capture made visible.
            //
            // Both tests are identity, not overlap. An ancestor overlaps the
            // child it contains, so an overlap test would light up every
            // container with a pressable child in it.
            var bg_now: ?Fill = pick(self.bg, self.bg_grad, null);
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
                if (hov.out) |out| try out.append(gpa, .{ .rect = rect, .clip = clip, .key = self.key, .active = !self.disabled });
            }
            // A button or bar always fills, even with no `bg` set, so the
            // kind default belongs here rather than in the kind's paint arm.
            // It has to be resolved in exactly one place: when the kind arm
            // drew its own fill as well, a button with `bg` set emitted two
            // quads over the same rect (invisible, but wrong -- and it made
            // prim counts a lie).
            // One foreground decision for every kind: a disabled control keeps
            // its geometry and drops to the muted role, which is the only
            // signal it gets, since the theme has no disabled colour and
            // cannot get one without duplicating a Mocha step.
            const fg_now: Fill = if (self.disabled) .{ .solid = th.text_muted } else pick(self.fg, self.fg_grad, .{ .solid = th.text }).?;
            const border_now: ?Fill = pick(self.border, self.border_grad, null);
            const fill_now: ?Fill = bg_now orelse switch (self.kind) {
                .button, .bar => .{ .solid = th.control },
                else => null,
            };
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
            if (self.on_press) |m| try hitAppend(M, hits, gpa, rect, clip, m, self.key, !self.disabled);

            switch (self.kind) {
                .text => |t| {
                    // Glyphs start inside the padding, matching `measure`.
                    const ix = rect.x + self.pad;
                    const iy = rect.y + self.pad;
                    const iw = rect.w - 2 * self.pad;
                    if (!self.wrap or iw <= 0) {
                        r.text(ix, iy, t.size, fg_now, t.bytes, clip);
                    } else {
                        var buf: [max_lines][]const u8 = undefined;
                        const n = r.wrapText(t.bytes, t.size, iw, &buf);
                        const ts = r.measureText(t.bytes, t.size);
                        for (buf[0..n], 0..) |line, i| {
                            if (line.len == 0) continue;
                            r.text(ix, iy + @as(f32, @floatFromInt(i)) * ts.line_height, t.size, fg_now, line, clip);
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
                    r.quad(fill, pick(self.fg, self.fg_grad, .{ .solid = th.accent }).?, clip);
                },

                .rect => {},

                .column => |c| {
                    if (child_clip.isEmpty()) return;
                    var y = rect.y + self.pad;
                    const inner_w = (self.width orelse rect.w) - 2 * self.pad;
                    for (c.children, 0..) |ch, i| {
                        if (i > 0) y += self.gap;
                        y += ch.space_before;
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, inner_w);
                        const w = ch.width orelse inner_w;
                        try ch.paint(r, .{ .x = rect.x + self.pad, .y = y, .w = w, .h = cs.h }, child_clip, ptr, hits, gpa, hov, th);
                        y += cs.h;
                        y += ch.space_after;
                    }
                },

                .row => |c| {
                    if (child_clip.isEmpty()) return;
                    var x = rect.x + self.pad;
                    const inner_h = (self.height orelse rect.h) - 2 * self.pad;
                    const avail_w = (self.width orelse rect.w) - 2 * self.pad;
                    for (c.children, 0..) |ch, i| {
                        if (i > 0) x += self.gap;
                        x += ch.space_before;
                        if (self.disabled) ch.disabled = true;
                        const cs = ch.measure(r, avail_w);
                        const w = ch.width orelse cs.w;
                        try ch.paint(r, .{ .x = x, .y = rect.y + self.pad, .w = w, .h = inner_h }, child_clip, ptr, hits, gpa, hov, th);
                        x += w;
                        x += ch.space_after;
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

        pub fn init(gpa: Allocator) Self {
            return .{
                .arena = .init(gpa),
                .dead = .{ .kind = .{ .rect = {} } },
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
        pub fn failFmt(self: *Self, kind: FailKind, comptime fmt: []const u8, args: anytype) void {
            self.failed = true;
            self.fail_kind = kind;
            // Truncation is fine here: the band is one line, and a message
            // that long is a diagnostic nobody could read in it anyway.
            const written = std.fmt.bufPrint(&self.fail_buf, fmt, args) catch self.fail_buf[0..];
            self.fail_len = written.len;
        }

        /// Raise a failure that OUTLIVES the next frame reset.
        ///
        /// `frame()` zeroes per-build state on entry, which is right for an
        /// allocation that failed inside `view` -- it describes that build and
        /// nothing else. A theme file that will not parse is not a property of
        /// a build: the runner discovers it between frames, and the band has to
        /// still be saying so on the frame after. Same band, two lifetimes.
        pub fn failExternal(self: *Self, kind: FailKind, comptime fmt: []const u8, args: anytype) void {
            self.ext_kind = kind;
            const written = std.fmt.bufPrint(&self.ext_buf, fmt, args) catch self.ext_buf[0..];
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

        fn mk(self: *Self, kind: Elem.Kind) *Elem {
            const e = self.alloc().create(Elem) catch {
                self.failWith(.layout_allocation);
                return &self.dead;
            };
            e.* = .{ .kind = kind };
            return e;
        }

        fn dupeKids(self: *Self, items: []const *Elem) []const *Elem {
            return self.alloc().dupe(*Elem, items) catch {
                self.failWith(.layout_allocation);
                return &.{};
            };
        }

        pub fn column(self: *Self, items: []const *Elem) *Elem {
            return self.mk(.{ .column = .{ .children = self.dupeKids(items) } });
        }

        pub fn row(self: *Self, items: []const *Elem) *Elem {
            return self.mk(.{ .row = .{ .children = self.dupeKids(items) } });
        }

        /// Text in the body colour. `fg` is left unset because that is the
        /// paint default: one fewer field written per element, and a caller
        /// who wants another colour just assigns one.
        pub fn text(self: *Self, bytes: []const u8, size: f32) *Elem {
            return self.mk(.{ .text = .{ .bytes = bytes, .size = size } });
        }

        pub fn muted(self: *Self, bytes: []const u8, size: f32) *Elem {
            const e = self.mk(.{ .text = .{ .bytes = bytes, .size = size } });
            e.fg = self.theme.text_muted;
            return e;
        }

        pub fn textFmt(self: *Self, comptime fmt: []const u8, args: anytype, size: f32) *Elem {
            const s = std.fmt.allocPrint(self.alloc(), fmt, args) catch {
                self.failWith(.layout_allocation);
                return &self.dead;
            };
            return self.text(s, size);
        }

        pub fn button(self: *Self, label: []const u8, msg: M) *Elem {
            const e = self.mk(.{ .button = .{ .label = label, .size = 16 } });
            // The click is an element fact, not a button fact: the generic
            // `on_press` hit path already registers it, so the button kind
            // does not need to carry the message as well.
            e.on_press = msg;
            e.bg = self.theme.control;
            e.fg = self.theme.text;
            e.hover_bg = .{ .solid = self.theme.hover };
            e.press_bg = .{ .solid = self.theme.pressed };
            return e;
        }

        pub fn bar(self: *Self, value: f32) *Elem {
            const e = self.mk(.{ .bar = .{ .value = value } });
            e.bg = self.theme.control;
            e.fg = self.theme.accent;
            return e;
        }

        /// Uneven spacing lives on the child it separates, so no spacer ever
        /// occupies a slot in the child list: `gap` covers the uniform case and
        /// these two cover the rest.
        pub fn spaceBefore(self: *Self, e: *Elem, size: f32) *Elem {
            _ = self;
            e.space_before += size;
            return e;
        }

        pub fn spaceAfter(self: *Self, e: *Elem, size: f32) *Elem {
            _ = self;
            e.space_after += size;
            return e;
        }

        /// A plain sized box. Formerly you had to abuse `bar` for this.
        pub fn rect(self: *Self, w: f32, h: f32) *Elem {
            const e = self.mk(.rect);
            e.width = w;
            e.height = h;
            return e;
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
        pub fn hit(self: *const Self, p: [2]f32) ?Hit(M) {
            var i = self.hits.len;
            while (i > 0) {
                i -= 1;
                const h = self.hits[i];
                if (h.rect.contains(p) and h.clip.contains(p)) return if (h.active) h else null;
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
            if (!h.rect.contains(p) or !h.clip.contains(p)) return null;
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
                            self.captured = nh;
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
        /// Where layout gets its glyph metrics. This is the renderer that will
        /// draw the frame: if it is anything else, text is measured at one
        /// width and painted at another.
        metrics: Renderer,

        pub fn renderer(self: *Self) Renderer {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        const vtable = Renderer.VTable{
            .quad = vtQuad,
            .rrect = vtRrect,
            .text = vtText,
            .measure_text = vtMeasure,
            .wrap_text = vtWrap,
        };

        fn vtQuad(ptr: *anyopaque, rect: Rect, fill: Fill, clip: Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (rect.intersect(clip).isEmpty()) return;
            self.prims.append(self.gpa, .{ .quad = .{ .rect = rect, .fill = fill, .clip = clip } }) catch {};
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
            } }) catch {};
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
            } }) catch {};
        }

        fn vtMeasure(ptr: *anyopaque, bytes: []const u8, size: f32) TextMetrics {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.measureText(bytes, size);
        }

        fn vtWrap(ptr: *anyopaque, bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.metrics.wrapText(bytes, size, max_width, out);
        }
    };
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
        .rrect = nominalRrect,
        .text = nominalText,
        .measure_text = nominalMeasure,
        .wrap_text = nominalWrap,
    } };
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

fn nominalQuad(_: *anyopaque, _: Rect, _: Fill, _: Rect) void {}
fn nominalRrect(_: *anyopaque, _: Rect, _: f32, _: Fill, _: bool, _: Rect) void {}
fn nominalText(_: *anyopaque, _: f32, _: f32, _: f32, _: Fill, _: []const u8, _: Rect) void {}
// ---------------------------------------------------------------------------
// messages / runtime
// ---------------------------------------------------------------------------

/// What `update` asks the runtime to do after a message.
pub fn Action(comptime M: type) type {
    return struct {
        repaint: bool = true,
        quit: bool = false,
        /// work to run off the UI thread; its result comes back as a message
        cmd: ?Cmd(M) = null,

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
        threads: std.ArrayList(std.Thread) = .empty,
        outstanding: usize = 0, // guarded by mutex

        pub fn submit(self: *Self, cmd: Cmd(M)) void {
            self.mutex.lock();
            self.outstanding += 1;
            self.mutex.unlock();

            const t = std.Thread.spawn(.{}, worker, .{ self, cmd }) catch {
                self.mutex.lock();
                self.outstanding -= 1;
                self.mutex.unlock();
                return;
            };
            self.threads.append(self.gpa, t) catch {};
        }

        fn worker(self: *Self, cmd: Cmd(M)) void {
            const out = cmd.run(cmd.ctx);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (out) |m| self.done.append(self.gpa, m) catch {};
            self.outstanding -= 1;
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
            for (self.threads.items) |t| t.join();
            self.threads.deinit(self.gpa);
            self.done.deinit(self.gpa);
        }
    };
}

pub const Event = union(enum) {
    /// window wants to close; the runner stops.
    quit,
    pointer_down: [2]f32,
    pointer_up: [2]f32,
    pointer_move: [2]f32,
    /// The gesture ended without a release we will ever see: focus taken away,
    /// or the pointer left the window mid-drag. Without this the press claim
    /// outlives the gesture and the pressed element stays lit forever.
    pointer_cancel,
    key: u8,
};

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
        /// Hand a finished RGBA frame to the screen.
        present: *const fn (ptr: *anyopaque, pixels: []const u8, logical: Size) void,
        /// Logical window size, in the same units events are reported in.
        size: *const fn (ptr: *anyopaque) Size,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn poll(self: Window, timeout_ms: i32) ?Event {
        return self.vtable.poll(self.ptr, timeout_ms);
    }

    pub fn present(self: Window, pixels: []const u8, logical: Size) void {
        self.vtable.present(self.ptr, pixels, logical);
    }

    pub fn size(self: Window) Size {
        return self.vtable.size(self.ptr);
    }

    pub fn deinit(self: Window) void {
        self.vtable.deinit(self.ptr);
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
            if (action.cmd) |cmd| {
                if (self.exec == null) self.exec = Executor(M){ .gpa = self.gpa };
                self.exec.?.submit(cmd);
            }
            return action;
        }

        /// Messages produced by commands since the last call. Dispatch them
        /// from the UI thread; they are ordinary messages.
        pub fn takeAsync(self: *Self, list: *std.ArrayList(M)) !void {
            if (self.exec) |*e| try e.drainInto(list);
        }

        /// True while a command is still running.
        pub fn asyncBusy(self: *Self) bool {
            if (self.exec) |*e| return e.busy();
            return false;
        }

        /// view -> measure -> paint. Returns primitives plus hit regions.
        ///
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

            const root = self.viewFn(&self.state, &self.ui);

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

            try root.paint(r, root_rect, Rect.unbounded, view, &hits, a, .{ .target = resolved }, self.ui.theme);

            // Keys are identity, and identity that collides is worse than no
            // identity: `rebind` would bind a press to whichever twin it met
            // first. So it is a bug -- but not one worth taking the app down
            // for. It is reported the same way a failed allocation is, through
            // the band, which keeps the frame usable and names the fault.
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
    const minus = ui.button("-", .dec);
    minus.width = 40;
    const plus = ui.button("+", .inc);
    plus.width = 40;
    return ui.column(&.{
        ui.textFmt("{d}", .{s.n}, 20),
        ui.row(&.{ minus, plus }),
    });
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
        _ = ui.text("hello", 12);
        _ = ui.column(&.{ui.text("a", 12)});
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
    const spacer = ui.rect(10, 10);
    spacer.height = 10 + @as(f32, @floatFromInt(@mod(s.n, 4))) * 20;
    const b = ui.button("-", .dec);
    b.width = 40;
    return ui.column(&.{ spacer, b });
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
    return ui.column(kids[0..n]);
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
    const box = ui.rect(80, 40);
    box.bg = ui.theme.panel;
    box.bg_grad = Fill.vgrad(ui.theme.accent, ui.theme.bg);
    box.border = ui.theme.border;
    box.border_grad = Fill.hgrad(ui.theme.accent, ui.theme.text_muted);
    const label = ui.text("grad", 12);
    label.fg_grad = Fill.hgrad(ui.theme.accent, ui.theme.text_muted);
    return ui.column(&.{ box, label });
}

fn kView(s: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button("a", .first);
    a.key = 1;
    const b = ui.button("b", .second);
    b.key = 2;
    b.disabled = s.disabled;
    return switch (s.mode) {
        .normal => ui.column(&.{ a, b }),
        .swapped => ui.column(&.{ b, a }),
        .only_a => ui.column(&.{a}),
    };
}

/// No keys: the rect-based path, which must keep working exactly as before.
fn plainView(s: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button("a", .first);
    a.disabled = s.disabled;
    return a;
}

fn parentOffView(_: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button("a", .first);
    const b = ui.button("b", .second);
    const col = ui.column(&.{ a, b });
    col.disabled = true; // the container is off; the buttons never said so
    return col;
}

fn dupView(_: *KState, ui: *Ui(KMsg)) *Element(KMsg) {
    const a = ui.button("a", .first);
    a.key = 7;
    const b = ui.button("b", .second);
    b.key = 7;
    return ui.column(&.{ a, b });
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
    const long = "x" ** 232;
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
    return ui.button("x", .first);
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
    };
}

// ---------------------------------------------------------------------------
// theme files
// ---------------------------------------------------------------------------
