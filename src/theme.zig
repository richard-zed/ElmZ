//! Themes: the palette roles, the guard that keeps them readable, and the `.zon` loader.

const std = @import("std");
const elmz = @import("elmz.zig");
const Theme = elmz.Theme;
const Color = elmz.Color;
const Allocator = std.mem.Allocator;

/// Roles are grouped by what a collision costs, because a duplicate between two roles is
/// only a bug when the two have to be told apart.
pub const RoleFamily = enum {
    /// Fill states that must be distinguishable from each other while a control changes
    /// state.
    interaction,
    /// Text on a panel: primary and secondary must differ or nothing reads as
    /// de-emphasised.
    text,
    /// The two large adjacent fills.
    fill,
    /// Lines. A single role, so it can alias freely: a border in the caption colour is a
    /// theme author spending fewer tokens, not a defect.
    line,
    /// Emphasis, checked only against itself.
    emphasis,
};

/// Every field must appear exactly once: an unfiled token is `error.UnfiledRole`, so a role
/// added to `Theme` cannot be outgrown by the guard silently.
pub fn familyOf(name: []const u8) ?RoleFamily {
    const pairs = .{
        .{ "control", RoleFamily.interaction },
        .{ "hover", RoleFamily.interaction },
        .{ "pressed", RoleFamily.interaction },
        .{ "selected", RoleFamily.interaction },
        .{ "text", RoleFamily.text },
        .{ "text_muted", RoleFamily.text },
        .{ "bg", RoleFamily.fill },
        .{ "panel", RoleFamily.fill },
        .{ "border", RoleFamily.line },
        .{ "accent", RoleFamily.emphasis },
        // The three outcome roles are emphasis singletons too: a toast bar in
        // the accent colour would read as "informational chrome" rather than as
        // an outcome, so they are filed where they must stay distinct from it.
        .{ "success", RoleFamily.emphasis },
        .{ "warning", RoleFamily.emphasis },
        .{ "fail", RoleFamily.emphasis },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// A same-family pair sharing one colour.
const Collision = struct {
    family: RoleFamily,
    a: []const u8,
    b: []const u8,
};

/// The first pair of same-family roles sharing a colour, or null when the palette is legal.
/// Returned rather than printed.
pub fn firstCollision(t: Theme) ?Collision {
    const fields = @typeInfo(Theme).@"struct".fields;
    inline for (fields, 0..) |f, i| {
        if (comptime std.mem.eql(u8, f.name, "custom")) continue;
        // `if`-capture, not `orelse continue`: `continue` inside an inline for
        // is comptime control flow in a runtime block, which does not compile.
        if (familyOf(f.name)) |fi| {
            inline for (fields[i + 1 ..]) |g| {
                if (comptime std.mem.eql(u8, g.name, "custom")) continue;
                if (familyOf(g.name)) |gi| {
                    if (fi == gi and std.meta.eql(@field(t, f.name), @field(t, g.name)))
                        return .{ .family = fi, .a = f.name, .b = g.name };
                }
            }
        }
    }
    return null;
}

/// Two roles may share a colour only if they belong to DIFFERENT families.
fn checkPalette(t: Theme) !void {
    const fields = @typeInfo(Theme).@"struct".fields;
    inline for (fields) |f| {
        // `custom` is the side table for names a file invented; it is a slice,
        // not a role, and has no family to file under.
        if (comptime !std.mem.eql(u8, f.name, "custom")) {
            if (familyOf(f.name) == null) return error.UnfiledRole;
        }
    }
    if (firstCollision(t) != null) return error.DuplicateRole;
}

// ---------------------------------------------------------------------------
// theme files, v2: values only, nested sections, gradients as data
// ---------------------------------------------------------------------------
//
// A theme file is DATA. ZON rejects arithmetic, `@import`, `comptime(...)` and
// trailing documents (all verified by compiling), so there is no evaluation
// path: a file cannot compute a colour, call a function, or reach anything
// outside itself. That is a property of the parser, not of our loader -- which
// is exactly why the loader can keep this short.
//
// v1 was flat: ten hex roles and nothing else. That shape cannot carry a
// gradient, and a gradient is not decoration -- `Fill` has been a union for a
// while and the renderer draws four kinds of them, so the one thing a theme
// could not express was the thing the renderer did best.
//
// v2 splits the section in two, so each keeps its natural syntax:
//
//   .colors    = .{ .bg = .{ .hex = 0x1e1e2e } }             -- terse, the common case,
//                                                   what a person edits by hand
//   .gradients = .{ .bg = .{ .linear = ... } }   -- explicit, because a
//                                                   gradient is not a number
//
// Keeping `.colors` as hex is not laziness: ZON will not coerce a bare integer
// into a union payload (verified by compiling), so a single unified field would
// force `.{ .solid = 0x1e1e2e }` on all thirteen roles, in every file, forever.

/// The shipped listing is the library default. Embedded rather than shipped beside the
/// binary so a missing file cannot quietly become "no theme".
pub const defaults_zon: [:0]const u8 = @embedFile("theme.defaults.zon");

/// Every loader version this file understands. A file states its own so a v1 file is
/// refused in one sentence instead of half-loading and looking wrong.
pub const theme_version: u32 = 3;

/// Gradient direction for the linear case: degrees on a clock face, clockwise from 12
/// o'clock, naming the direction the ramp TRAVELS.
pub const LinearSpec = struct {
    dir: f32 = 180,
    /// `null` inherits the role's own colour from `.colors`.
    from: ?u32 = null,
    to: ?u32 = null,
};

pub const RadialSpec = struct {
    /// The colour at the centre and the colour it falls off to. `null` inherits the role's
    /// own colour, same as the linear ends.
    inner: ?u32 = null,
    outer: ?u32 = null,
    /// Where the centre sits, as a fraction of the element's box. `.{0, 0}` is the top-left
    /// corner, `.{0.5, 0.5}` the middle.
    center: ?[2]f32 = null,
    /// Fraction of the box WIDTH, matching `Fill.Radial`.
    radius: f32 = 0.5,
};

/// A gradient as written in a file.
pub const GradientSpec = union(enum) {
    linear: LinearSpec,
    radial: RadialSpec,

    /// `fallback` is the role's resolved colour, used for whichever end the file left out.
    pub fn resolve(self: GradientSpec, fallback: Color) elmz.Fill {
        return switch (self) {
            .linear => |l| blk: {
                const a = if (l.from) |h| Color.rgbHex(h) else fallback;
                const b = if (l.to) |h| Color.rgbHex(h) else fallback;
                // A unit direction centred on the box: the ramp spans the whole
                // element whatever the angle, so turning it never shrinks it.
                break :blk elmz.Fill.angled(l.dir, a, b);
            },
            .radial => |r| blk: {
                const a = if (r.inner) |h| Color.rgbHex(h) else fallback;
                const b = if (r.outer) |h| Color.rgbHex(h) else fallback;
                var f = elmz.Fill.radialFill(a, b);
                f.radial.radius = r.radius;
                if (r.center) |c| f.radial.center = c;
                break :blk f;
            },
        };
    }
};

/// Solid colours, as written. Every field optional, `null` meaning "inherit".
pub const ColorsSpec = struct {
    bg: ColorSpec = .{},
    panel: ColorSpec = .{},
    border: ColorSpec = .{},
    text: ColorSpec = .{},
    text_muted: ColorSpec = .{},
    control: ColorSpec = .{},
    hover: ColorSpec = .{},
    pressed: ColorSpec = .{},
    selected: ColorSpec = .{},
    accent: ColorSpec = .{},
    success: ColorSpec = .{},
    warning: ColorSpec = .{},
    fail: ColorSpec = .{},

    /// Colours beyond the built-in roles, as a LIST because ZON cannot parse a map -- the
    /// same reason `.styles` is a list.
    roles: []const CustomRole = &.{},

    /// `base` supplies whatever the spec leaves null.
    pub fn overlay(self: ColorsSpec, base: Theme) Theme {
        var t = base;
        inline for (@typeInfo(ColorsSpec).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "roles")) continue;
            if (@field(self, f.name).resolve()) |c| {
                @field(t, f.name) = c;
            } else |_| {}
        }
        return t;
    }
};

/// A colour written in a file, in any free-form spelling.
pub const ColorValue = struct {
    pub const Error = error{
        NotAColour,
        ColourElementCount,
        ColourMixedFloats,
        ColourOutOfRange,
        ColourNegative,
        ColourBigInt,
    };

    /// Read a node as a colour. `zoir` is the untyped tree the ZON parse produced.
    pub fn read(ast: std.zig.Ast, zoir: std.zig.Zoir, node: std.zig.Zoir.Node.Index) Error!Color {
        _ = ast;
        return switch (node.get(zoir)) {
            .int_literal => |v| hexFromInt(v),
            .float_literal => error.NotAColour,
            .array_literal => |range| fromArray(zoir, range),
            else => error.NotAColour,
        };
    }

    /// `0xRRGGBB` or `0xRRGGBBAA`, by magnitude not by digit count: a value above 24 bits
    /// carries alpha.
    fn hexFromInt(int: anytype) Error!Color {
        switch (int) {
            .small => |i| {
                if (i < 0) return error.ColourNegative;
                const u = std.math.cast(u32, i) orelse return error.ColourOutOfRange;
                return if (u > 0xffffff) Color.rgbaHex(u) else Color.rgbHex(u);
            },
            .big => |val| {
                const u = val.toInt(u32) catch return error.ColourOutOfRange;
                return if (u > 0xffffff) Color.rgbaHex(u) else Color.rgbHex(u);
            },
        }
    }

    fn fromArray(zoir: std.zig.Zoir, range: std.zig.Zoir.Node.Index.Range) Error!Color {
        const n = range.len;
        if (n != 3 and n != 4) return error.ColourElementCount;

        var ch: [4]u8 = .{ 0, 0, 0, 255 };
        var any_float = false;
        var any_gt_one = false;
        var raw: [4]f64 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const node = range.at(@intCast(i));
            switch (node.get(zoir)) {
                .int_literal => |iv| switch (iv) {
                    .small => |s| {
                        if (s < 0) return error.ColourNegative;
                        if (s > 255) return error.ColourOutOfRange;
                        raw[i] = @floatFromInt(s);
                        if (@as(f64, @floatFromInt(s)) > 1.0) any_gt_one = true;
                    },
                    .big => return error.ColourBigInt,
                },
                .float_literal => |f| {
                    any_float = true;
                    if (f < 0) return error.ColourNegative;
                    raw[i] = @floatCast(f);
                    if (f > 1.0) any_gt_one = true;
                },
                else => return error.NotAColour,
            }
        }

        // Magnitude decides the scale, on the WHOLE array: all <= 1.0 is a
        // fraction, any > 1.0 is an 0-255 channel. A mixed array has no reading
        // that matches what the author meant, so it is an error rather than a
        // guess -- `.{ 1.0, 0.5, 200 }` is neither.
        if (any_float) {
            var all_le_one = true;
            var all_gt_one = true;
            for (raw[0..n]) |c| {
                if (c > 1.0) all_le_one = false;
                if (c <= 1.0) all_gt_one = false;
            }
            if (!all_le_one and !all_gt_one) return error.ColourMixedFloats;
            if (all_le_one) {
                for (raw[0..n], 0..) |c, k| {
                    const scaled = @round(c * 255.0);
                    if (scaled > 255.0) return error.ColourOutOfRange;
                    ch[k] = @intFromFloat(scaled);
                }
                return .{ .r = ch[0], .g = ch[1], .b = ch[2], .a = ch[3] };
            }
        }

        for (raw[0..n], 0..) |c, k| {
            if (c < 0 or c > 255) return error.ColourOutOfRange;
            ch[k] = @intFromFloat(@round(c));
        }
        return .{ .r = ch[0], .g = ch[1], .b = ch[2], .a = ch[3] };
    }
};

/// A colour value as a file may write it.
pub const ColorSpec = struct {
    hex: ?u32 = null,
    rgb: ?[3]u8 = null,
    rgba: ?[4]u8 = null,

    pub const Error = error{ColorNotOneForm};

    /// Fold to a `Color`. Six-digit hex is opaque, eight is `0xRRGGBBAA`, both handled by
    /// `Color.hex` -- the same rule the built-in roles already use.
    pub fn resolve(self: ColorSpec) Error!elmz.Color {
        var seen: u2 = 0;
        var out: elmz.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0xff };
        if (self.hex) |h| {
            seen += 1;
            out = elmz.Color.hex(h);
        }
        if (self.rgb) |v| {
            seen += 1;
            out = .{ .r = v[0], .g = v[1], .b = v[2], .a = 0xff };
        }
        if (self.rgba) |v| {
            seen += 1;
            out = .{ .r = v[0], .g = v[1], .b = v[2], .a = v[3] };
        }
        if (seen != 1) return error.ColorNotOneForm;
        return out;
    }

    /// A plain hex, for tests and for code paths that already have one.
    pub fn fromHex(h: u32) ColorSpec {
        return .{ .hex = h };
    }
};

/// One named colour outside the built-in set. `value` takes either form: `.name = "chart1",
/// .value = .{ .hex = 0x...
pub const CustomRole = struct {
    name: []const u8,
    value: ColorSpec,
};

/// Gradients per role, named exactly like the colours they stand in for.
pub const GradientsSpec = struct {
    bg: ?GradientSpec = null,
    panel: ?GradientSpec = null,
    border: ?GradientSpec = null,
    text: ?GradientSpec = null,
    text_muted: ?GradientSpec = null,
    control: ?GradientSpec = null,
    hover: ?GradientSpec = null,
    pressed: ?GradientSpec = null,
    selected: ?GradientSpec = null,
    accent: ?GradientSpec = null,
    success: ?GradientSpec = null,
    warning: ?GradientSpec = null,
    fail: ?GradientSpec = null,

    /// Gradients for colours the file invented.
    roles: []const CustomGradient = &.{},
};

/// One named gradient outside the built-in set.
pub const CustomGradient = struct {
    name: []const u8,
    gradient: GradientSpec,
};

/// The resolved gradients: a role with no gradient is null, which is how every consumer
/// spells "use the solid colour".
pub const Gradients = struct {
    bg: ?elmz.Fill = null,
    panel: ?elmz.Fill = null,
    border: ?elmz.Fill = null,
    text: ?elmz.Fill = null,
    text_muted: ?elmz.Fill = null,
    control: ?elmz.Fill = null,
    hover: ?elmz.Fill = null,
    pressed: ?elmz.Fill = null,
    selected: ?elmz.Fill = null,
    accent: ?elmz.Fill = null,
    success: ?elmz.Fill = null,
    warning: ?elmz.Fill = null,
    fail: ?elmz.Fill = null,

    /// Gradients for the file's own roles. A slice, not fields, for the same reason
    /// `Theme.custom` is: names are data here, not schema.
    custom: []const CustomFill = &.{},

    pub const CustomFill = struct { name: []const u8, fill: elmz.Fill };

    pub fn any(self: Gradients) bool {
        inline for (@typeInfo(Gradients).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "custom")) continue;
            if (@field(self, f.name) != null) return true;
        }
        return self.custom.len > 0;
    }

    /// The gradient for a role by name, or null. Lets an app say
    /// `ui.gradients.get("accent")` without knowing the whole shape.
    pub fn get(self: Gradients, name: []const u8) ?elmz.Fill {
        inline for (@typeInfo(Gradients).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "custom")) continue;
            if (std.mem.eql(u8, name, f.name)) return @field(self, f.name);
        }
        // A name the file defined. Checked last so a custom name can never
        // shadow a built-in one -- the loader refuses that case outright.
        for (self.custom) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.fill;
        }
        return null;
    }
};

/// Longest font name a theme file may carry. A name is a name, not a description: a hundred
/// bytes means the author pasted a path.
pub const font_name_max = 96;

/// One theme section as written: two nested tables, both optional.
pub const ThemeSpec = struct {
    colors: ColorsSpec = .{},
    gradients: GradientsSpec = .{},

    /// The typeface, BY NAME: `.font = "DejaVu Sans"`.
    font: ?[]const u8 = null,

    /// Solid colours over `base`. Gradients resolve separately because they are a different
    /// type and a different question.
    pub fn overlay(self: ThemeSpec, base: Theme) Theme {
        return self.colors.overlay(base);
    }

    /// `theme` is the already-resolved palette, which is where an omitted gradient end gets
    /// its colour.
    pub fn resolveGradients(self: ThemeSpec, theme: Theme) Gradients {
        var out: Gradients = .{};
        inline for (@typeInfo(GradientsSpec).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "roles")) continue;
            if (@field(self.gradients, f.name)) |spec| {
                @field(out, f.name) = spec.resolve(@field(theme, f.name));
            }
        }
        return out;
    }
};

/// One named style: a bag of role REFERENCES, plus a font name.
pub const StyleSpec = struct {
    bg: ?[]const u8 = null,
    color: ?[]const u8 = null,
    border: ?[]const u8 = null,
    font: ?[]const u8 = null,
    size: ?f32 = null,
    weight: ?u16 = null,
    halo: ?HaloSpec = null,
    frost: ?FrostSpec = null,
    /// Outline width in pixels. Absent draws the fill solid; a value draws the
    /// fill as an outline of that width, leaving the interior hollow.
    stroke: ?u8 = null,
};

/// Blur of what is behind an element, in the theme file.
pub const FrostSpec = struct {
    blur: f32 = 12,
};

/// A glow or shadow in a theme file.
pub const HaloSpec = struct {
    color: []const u8 = "text_muted",
    blur: f32 = 12,
    spread: f32 = 0,
    offset: [2]f32 = .{ 0, 0 },
    light: ?f32 = null,
    mode: elmz.Halo.Mode = .glow,
    quality: elmz.Halo.Quality = .baked,
};

/// The named styles, as a LIST rather than a map.
pub const StylesSpec = []const StyleEntry;

pub const StyleEntry = struct {
    name: []const u8,
    spec: StyleSpec = .{},
    /// How many other styles this one's `.font` names, so the loader can find a cycle
    /// without walking a map it does not have.
    pub fn fontRef(self: StyleEntry) ?[]const u8 {
        return self.spec.font;
    }
};

/// The whole document. `.vars` is typed by whoever claims it. There is no lenient mode.
pub fn ThemeFileType(comptime App: type) type {
    return struct {
        version: u32,
        theme: ThemeSpec = .{},
        /// Named styles, resolved against this file's own palette.
        styles: StylesSpec = &.{},
        /// The app tier.
        vars: App = .{},
    };
}

/// What a load produced: the palette, its gradients, and the app tier.
pub fn Loaded(comptime App: type) type {
    return struct {
        theme: Theme,
        gradients: Gradients = .{},
        vars: App = .{},
        /// COPIED out of the parse result, which `loadTheme` frees before returning: the
        /// keys and the string values come from that allocation.
        styles: StylesSpec = &.{},
        /// The font name is COPIED, not borrowed: the parse result owns its strings and is
        /// freed before this is returned, so a slice into it would dangle.
        font_buf: [font_name_max]u8 = undefined,
        font_len: usize = 0,

        pub fn fontName(self: *const @This()) ?[]const u8 {
            return if (self.font_len == 0) null else self.font_buf[0..self.font_len];
        }
    };
}

/// One line, fixed capacity. The failure path is the last place that may assume an
/// allocator survived, and the band is one line wide anyway.
pub const ThemeDiag = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const ThemeDiag) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *ThemeDiag, comptime f: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, f, args) catch &self.buf;
        self.len = written.len;
    }
};

/// `Palette` is separate from `Parse` because a file can be perfectly valid ZON and still
/// be an unusable theme: two interaction roles sharing a colour.
pub const ThemeLoadError = error{ Parse, Version, Palette, Style, OutOfMemory };

/// First diagnostic, rendered as `name line:col: reason` -- the shape that tells an author
/// where to look.
fn diagFrom(diag: *ThemeDiag, name: []const u8, d: *std.zon.parse.Diagnostics, fallback: []const u8) void {
    var errors = d.iterateErrors();
    if (errors.next()) |err| {
        const loc = err.getLocation(d);
        diag.set("{s} {d}:{d}: {f}", .{ name, loc.line + 1, loc.column + 1, err.fmtMessage(d) });
        return;
    }
    diag.set("{s}: {s}", .{ name, fallback });
}

/// Parse `src` as a v2 theme file over `base`. Walker output -> the struct `loadTheme`
/// reads.
fn litEnd(l: ?ColorLit) ?u32 {
    const v = l orelse return null;
    return switch (v) {
        .hex => |h| h,
        .rgb, .rgba => null,
    };
}

fn specFromLit(g: GradientLit) ?GradientSpec {
    return switch (g) {
        .linear => |l| .{ .linear = .{
            .dir = l.dir,
            .from = litEnd(l.from),
            .to = litEnd(l.to),
        } },
        .radial => |r| .{ .radial = .{
            .inner = litEnd(r.inner),
            .outer = litEnd(r.outer),
            .center = r.center,
            .radius = r.radius,
        } },
    };
}

fn buildFileType(comptime App: type, gpa: Allocator, t: OpenTables, diag: *ThemeDiag, file_name: []const u8) ThemeLoadError!ThemeFileType(App) {
    var out: ThemeFileType(App) = .{ .version = theme_version };

    var customs = std.array_list.Managed(CustomRole).init(gpa);
    defer customs.deinit();

    for (t.colors) |c| {
        const spec: ColorSpec = switch (c.value) {
            .solid => |l| switch (l) {
                .hex => |h| .{ .hex = h },
                .rgb => |v| .{ .rgb = v },
                .rgba => |v| .{ .rgba = v },
            },
            .gradient => {
                diag.set("{s}: \"{s}\" is a gradient; put it in .gradients", .{ file_name, c.name });
                return error.Palette;
            },
        };
        // Runtime name, so `inline for` cannot decide the branch at comptime:
        // the field set is unrolled but the match is a runtime compare.
        var matched = false;
        inline for (@typeInfo(ColorsSpec).@"struct".fields) |f| {
            if (!comptime std.mem.eql(u8, f.name, "roles")) {
                if (std.mem.eql(u8, f.name, c.name)) {
                    @field(out.theme.colors, f.name) = spec;
                    matched = true;
                }
            }
        }
        if (!matched) {
            customs.append(.{
                .name = gpa.dupe(u8, c.name) catch return error.OutOfMemory,
                .value = spec,
            }) catch return error.OutOfMemory;
        }
    }
    if (customs.items.len > 0) {
        out.theme.colors.roles = customs.toOwnedSlice() catch return error.OutOfMemory;
    }

    var cgrads = std.array_list.Managed(CustomGradient).init(gpa);
    defer cgrads.deinit();
    for (t.gradients) |g| {
        var matched = false;
        inline for (@typeInfo(GradientsSpec).@"struct".fields) |f| {
            if (!comptime std.mem.eql(u8, f.name, "roles")) {
                if (std.mem.eql(u8, f.name, g.name)) {
                    @field(out.theme.gradients, f.name) = specFromLit(g.value) orelse {
                        diag.set("{s}: gradient \"{s}\" needs hex ends", .{ file_name, g.name });
                        return error.Palette;
                    };
                    matched = true;
                }
            }
        }
        if (!matched) {
            cgrads.append(.{
                .name = gpa.dupe(u8, g.name) catch return error.OutOfMemory,
                .gradient = specFromLit(g.value) orelse {
                    diag.set("{s}: gradient \"{s}\" needs hex ends", .{ file_name, g.name });
                    return error.Palette;
                },
            }) catch return error.OutOfMemory;
        }
    }
    if (cgrads.items.len > 0) {
        out.theme.gradients.roles = cgrads.toOwnedSlice() catch return error.OutOfMemory;
    }

    var styles = std.array_list.Managed(StyleEntry).init(gpa);
    defer styles.deinit();
    for (t.styles) |st| {
        var spec = st.value;
        inline for (.{ "bg", "color", "border", "font" }) |slot| {
            if (@field(spec, slot)) |str| @field(spec, slot) = gpa.dupe(u8, str) catch return error.OutOfMemory;
        }
        if (spec.halo) |h| {
            var nh = h;
            nh.color = gpa.dupe(u8, h.color) catch return error.OutOfMemory;
            spec.halo = nh;
        }
        styles.append(.{
            .name = gpa.dupe(u8, st.name) catch return error.OutOfMemory,
            .spec = spec,
        }) catch return error.OutOfMemory;
    }
    if (styles.items.len > 0) {
        out.styles = styles.toOwnedSlice() catch return error.OutOfMemory;
    }

    return out;
}

pub fn loadTheme(
    comptime App: type,
    gpa: Allocator,
    name: []const u8,
    src: [:0]const u8,
    base: Theme,
    diag: *ThemeDiag,
) ThemeLoadError!Loaded(App) {
    diag.len = 0;

    // The version is read before the schema is known, which makes this probe
    // the ONE legitimate use of `ignore_unknown_fields`: there is no schema yet
    // to judge the rest of the keys against.
    {
        const Probe = struct { version: u32 };
        var d: std.zon.parse.Diagnostics = .{};
        defer d.deinit(gpa);
        const probe = std.zon.parse.fromSlice(Probe, gpa, src, &d, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => {
                diagFrom(diag, name, &d, "not a theme file");
                return error.Parse;
            },
        };
        if (probe.version != theme_version) {
            diag.set("{s}: version {d} is not {d}", .{ name, probe.version, theme_version });
            return error.Version;
        }
    }

    // The palette and the styles are read by the WALKER, not by `zon.parse`.
    // A struct field accepts exactly one shape per name, and a theme file
    // writes several -- `0xRRGGBB`, `.{ r, g, b }`, `.{ 0.1, 0.2, 0.3 }` --
    // under names the file itself invents. The token stream carries the shape,
    // so the shape decides how a value is read.
    // The walker already distinguishes a malformed file from a bad palette
    // from a bad style, and `ThemeLoadError` can carry all three. Collapsing
    // every failure to `error.Parse` made the internal error more precise than
    // the one callers see, so a caller had to grep the diagnostic to tell them
    // apart. `Parse` is reserved for the typed `std.zon.parse` below.
    var tables = try readOpenTables(gpa, src, diag);
    defer freeOpenTables(gpa, &tables);

    // `.vars` is still typed: `App` is a struct the APP declares, so it is the
    // one section with a schema to check against.
    var d: std.zon.parse.Diagnostics = .{};
    defer d.deinit(gpa);
    // `.vars` sits INSIDE `.theme`, not at the root. Probing the root found
    // nothing, so the app tier was always the default and every `.weight` /
    // `.font` reference resolved to null -- the file looked loaded and every
    // var-driven style looked ignored.
    const AppOnly = struct { theme: struct { vars: App = .{} } = .{} };
    const app_tier = std.zon.parse.fromSliceAlloc(AppOnly, gpa, src, &d, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            diagFrom(diag, name, &d, "bad theme file");
            return error.Parse;
        },
    };
    // `.vars` string fields point INTO the parse result, which the defer below
    // frees. `built.vars` copied the struct, not the bytes, so every string var
    // dangled -- `vars.latin_font` read back as junk while the styles that
    // resolved from it looked fine, because those were separately copied.
    // Dupe the slices into `gpa` before the free; `freeVars` unwinds them.
    var vars_owned = app_tier.theme.vars;
    try dupeVars(App, gpa, &vars_owned);
    // OWNERSHIP TRANSFERS to the caller on success, so this must not run on
    // the happy path -- `out.vars` is `vars_owned`, and freeing it here is
    // what made `loaded.vars.latin_font` read back as junk.
    var vars_transferred = false;
    defer if (!vars_transferred) freeVars(App, gpa, &vars_owned);
    defer std.zon.parse.free(gpa, app_tier);

    // Walker output, reshaped into the one struct the rest of this function
    // reads. The FILE format is free-form; the handoff is not.
    var built = try buildFileType(App, gpa, tables, diag, name);
    defer freeFileType(App, gpa, &built);
    built.vars = vars_owned;

    var theme = built.theme.overlay(base);

    // The file's own role names. The strings live in the parse result, which is
    // freed on return, so they are COPIED into the caller's allocator before
    // this scope ends -- a borrowed slice would dangle and every custom role
    // would draw as the `text` fallback for reasons nothing could trace.
    if (built.theme.colors.roles.len > 0) {
        const custom = gpa.alloc(Theme.CustomColor, built.theme.colors.roles.len) catch return error.OutOfMemory;
        errdefer gpa.free(custom);
        var made: usize = 0;
        errdefer for (custom[0..made]) |c| gpa.free(c.name);
        // Two entries with the SAME name is the error, because one of them would
        // be silently dropped. A custom entry naming a built-in (`bg`, `accent`)
        // is allowed and overwrites it -- that is how a file retunes a role
        // without the built-in winning and making the file look ignored.
        for (built.theme.colors.roles, 0..) |r, i| {
            for (custom[0..made]) |seen| {
                if (std.mem.eql(u8, seen.name, r.name)) {
                    diag.set("{s}: .colors names \"{s}\" twice", .{ name, r.name });
                    return error.Palette;
                }
            }
            // Resolve BEFORE duping. The other order leaks: `made` only advances
            // after the whole entry is built, so a resolve failure would leave
            // the just-duped name allocated and nothing holding it. The leak was
            // two allocations in the reject tests, which is how it was found.
            const color = r.value.resolve() catch {
                diag.set("{s}: colour \"{s}\" sets none or more than one of .hex/.rgb/.rgba", .{ name, r.name });
                return error.Palette;
            };
            custom[i] = .{
                .name = gpa.dupe(u8, r.name) catch return error.OutOfMemory,
                .color = color,
            };
            made = i + 1;
        }
        theme.custom = custom;
    }

    // Custom gradients, resolved against the role they name. Done here rather
    // than in `resolveGradients` because that runs before `theme.custom` is
    // attached, so a custom role would resolve against `text`.
    var grad_out: Gradients = built.theme.resolveGradients(theme);
    if (built.theme.gradients.roles.len > 0) {
        const cf = gpa.alloc(Gradients.CustomFill, built.theme.gradients.roles.len) catch return error.OutOfMemory;
        errdefer gpa.free(cf);
        var made: usize = 0;
        errdefer for (cf[0..made]) |c| gpa.free(c.name);
        for (built.theme.gradients.roles, 0..) |g, i| {
            // A gradient name is the name being DEFINED. It can never be an
            // existing role, so rejecting non-role names here rejected every
            // custom gradient by construction -- and rejecting one key discards
            // the whole file, colours and vars included. The file is the
            // extension point; a name written in `.gradients` may be used by
            // styles and by other gradients.
            // An omitted end inherits `roleColor(theme, <own name>)`, which for
            // a name with no `.colors` entry is `text` -- the documented
            // fallback, not an accident.
            cf[i] = .{
                .name = gpa.dupe(u8, g.name) catch return error.OutOfMemory,
                .fill = g.gradient.resolve(elmz.roleColor(theme, g.name)),
            };
            made = i + 1;
        }
        grad_out.custom = cf;
    }

    // The shipped file is checked by the suite; a user's file is not, and it is
    // the one that can go wrong. A guard that only ever runs in tests protects
    // nothing the user will hit.
    checkPalette(theme) catch |e| {
        diag.set("{s}: {t}", .{ name, e });
        return error.Palette;
    };

    // Every style's role references are checked before any of it is used. A
    // name that is not a role is a typo, and a typo here means an element draws
    // with the wrong colour and says nothing.
    for (built.styles) |entry| {
        inline for (.{ "bg", "color", "border" }) |slot| {
            if (@field(entry.spec, slot)) |ref| {
                if (!isRole(ref, theme.custom) and
                    !isGradientName(ref, built.theme.gradients.roles))
                {
                    diag.set("{s}: style .{s} .{s} names \"{s}\", which is not a role", .{ name, entry.name, slot, ref });
                    return error.Style;
                }
            }
        }
    }
    try checkStyleCycles(diag, name, built.styles);

    var out: Loaded(App) = .{
        .theme = theme,
        .gradients = grad_out,
        .vars = built.vars,
    };

    // Deep copy: names and string values point into `file`, which the defer
    // above frees. Getting this wrong is a use-after-free that renders as
    // garbage role names, or as nothing at all.
    if (built.styles.len > 0) out.styles = try copyStyles(gpa, built.styles);
    vars_transferred = true;
    return out;
}

/// The view-side view of the style table, for `Ui.styleByName`.
pub fn styleView(styles: StylesSpec, out: *std.ArrayListUnmanaged(elmz.StyleEntry), gpa: Allocator) ![]elmz.StyleEntry {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(gpa, styles.len);
    for (styles) |e| {
        out.appendAssumeCapacity(.{
            .name = e.name,
            .spec = .{
                .bg = e.spec.bg,
                .color = e.spec.color,
                .border = e.spec.border,
                .font = e.spec.font,
                .size = e.spec.size,
                .weight = e.spec.weight,
                .halo = if (e.spec.halo) |h| .{
                    .color = h.color,
                    .blur = h.blur,
                    .spread = h.spread,
                    .offset = h.offset,
                    .light = h.light,
                    .mode = h.mode,
                    .quality = h.quality,
                } else null,
                .frost = if (e.spec.frost) |f| .{ .blur = f.blur } else null,
                .stroke = e.spec.stroke,
            },
        });
    }
    return out.items;
}

/// Free the custom-role table. Safe on a theme that has none.
pub fn freeCustom(gpa: std.mem.Allocator, t: *elmz.Theme) void {
    for (t.custom) |c| gpa.free(c.name);
    if (t.custom.len > 0) gpa.free(t.custom);
    t.custom = &.{};
}

/// Free the owned style table. Safe on the empty default.
pub fn freeStyles(gpa: std.mem.Allocator, styles: *StylesSpec) void {
    for (styles.*) |entry| freeSpecEntry(gpa, entry);
    if (styles.len > 0) gpa.free(styles.*);
    styles.* = &.{};
}

/// Free the walker's own table, which overlaps `elmz.StyleEntry` field for field but is a
/// separate type.
fn freeSpecEntry(gpa: std.mem.Allocator, entry: StyleEntry) void {
    inline for (.{ "bg", "color", "border", "font" }) |slot| {
        if (@field(entry.spec, slot)) |str| gpa.free(str);
    }
    if (entry.spec.halo) |h| gpa.free(h.color);
    gpa.free(entry.name);
}

/// Free what `buildFileType` allocated. Names, style strings and the custom slices are all
/// owned; the `ColorSpec`/`GradientLit` payloads are values.
fn freeFileType(comptime App: type, gpa: Allocator, f: *ThemeFileType(App)) void {
    for (f.theme.colors.roles) |r| gpa.free(r.name);
    if (f.theme.colors.roles.len > 0) gpa.free(f.theme.colors.roles);
    for (f.theme.gradients.roles) |g| gpa.free(g.name);
    if (f.theme.gradients.roles.len > 0) gpa.free(f.theme.gradients.roles);
    if (f.styles.len > 0) freeStyles(gpa, &f.styles);
}

/// Free the custom gradient table `loadTheme` built. Each entry owns a duped `name`; the
/// slice owns the entries.
pub fn freeGradients(gpa: Allocator, grads: *Gradients) void {
    for (grads.custom) |c| gpa.free(c.name);
    if (grads.custom.len > 0) gpa.free(grads.custom);
    grads.custom = &.{};
}

/// Free everything `loadTheme` handed back.
pub fn freeLoaded(comptime App: type, gpa: Allocator, loaded: *Loaded(App)) void {
    // The custom colour table lives on the THEME, not on the other three, so
    // it was the one table this never released -- every themed example leaked
    // one allocation per custom role, and DebugAllocator aborted at exit,
    // which read as a crash AFTER a successful render.
    freeCustom(gpa, &loaded.theme);
    freeStyles(gpa, &loaded.styles);
    freeVars(App, gpa, &loaded.vars);
    freeGradients(gpa, &loaded.gradients);
}

/// Deep-copy the string fields of an app's vars struct into `gpa`. `App` is declared by the
/// CONSUMER, so there is no fixed shape to copy.
fn dupeVars(comptime App: type, gpa: Allocator, vars: *App) ThemeLoadError!void {
    const info = @typeInfo(App);
    if (info != .@"struct") return;
    inline for (info.@"struct".fields) |f| {
        switch (f.type) {
            []const u8 => @field(vars, f.name) = try gpa.dupe(u8, @field(vars, f.name)),
            ?[]const u8 => if (@field(vars, f.name)) |s| {
                @field(vars, f.name) = try gpa.dupe(u8, s);
            },
            else => {},
        }
    }
}

/// Free what `dupeVars` allocated. Safe on a struct with no string fields.
pub fn freeVars(comptime App: type, gpa: Allocator, vars: *App) void {
    const info = @typeInfo(App);
    if (info != .@"struct") return;
    inline for (info.@"struct".fields) |f| {
        switch (f.type) {
            []const u8 => gpa.free(@field(vars, f.name)),
            ?[]const u8 => if (@field(vars, f.name)) |s| gpa.free(s),
            else => {},
        }
    }
}

fn copyStyles(gpa: std.mem.Allocator, src: []const StyleEntry) !StylesSpec {
    const out = try gpa.alloc(StyleEntry, src.len);
    errdefer gpa.free(out);
    var done: usize = 0;
    errdefer for (out[0..done]) |e| {
        inline for (.{ "bg", "color", "border", "font" }) |slot| {
            if (@field(e.spec, slot)) |str| gpa.free(str);
        }
        if (e.spec.halo) |h| gpa.free(h.color);
        gpa.free(e.name);
    };
    for (src, 0..) |entry, i| {
        var nv = entry.spec;
        inline for (.{ "bg", "color", "border", "font" }) |slot| {
            if (@field(entry.spec, slot)) |str| @field(nv, slot) = try gpa.dupe(u8, str);
        }
        if (entry.spec.halo) |h| {
            var nh = h;
            nh.color = try gpa.dupe(u8, h.color);
            nv.halo = nh;
        }
        out[i] = .{ .name = try gpa.dupe(u8, entry.name), .spec = nv };
        done = i + 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Open colour namespaces.
//
// `.colors` and `.gradients` are ONE namespace each: the thirteen built-in role
// names live in the same table as names the file invent (`.color1`,
// `.gradient1`), and any entry may overwrite a built-in. `std.zon.parse` cannot
// express that -- a typed field is exactly one shape, and these values are hex
// OR a 3-tuple OR a 4-tuple OR a gradient, decided per entry and only knowable
// from the literal (verified: a union rejects a bare hex with "expected union",
// a named struct rejects `.{200,200,20}` with "expected struct", and a fixed
// array rejects a 3-tuple when declared `[4]u8`). So these two keys are read
// from the token stream, and every other key still goes through the typed
// reader with its unknown-key rejection intact.
// ---------------------------------------------------------------------------

/// One colour as written. Resolution is a separate step because a tuple and a hex are
/// different literals that mean the same kind of thing.
pub const ColorLit = union(enum) {
    hex: u32,
    rgb: [3]u8,
    rgba: [4]u8,

    pub fn toColor(self: ColorLit) elmz.Color {
        return switch (self) {
            .hex => |h| elmz.Color.hex(h),
            .rgb => |v| .{ .r = v[0], .g = v[1], .b = v[2], .a = 255 },
            .rgba => |v| .{ .r = v[0], .g = v[1], .b = v[2], .a = v[3] },
        };
    }
};

/// What a `.colors` entry may hold: a solid colour, or a gradient.
pub const ColorEntry = union(enum) {
    solid: ColorLit,
    gradient: GradientLit,
};

/// A gradient as written. Ends are `ColorLit`, so `.to = .{255,0,0}` works beside `.to =
/// 0xff0000`.
pub const GradientLit = union(enum) {
    linear: struct { dir: f32 = 90, from: ?ColorLit = null, to: ?ColorLit = null },
    radial: struct {
        center: [2]f32 = .{ 0.5, 0.5 },
        radius: f32 = 0.5,
        inner: ?ColorLit = null,
        outer: ?ColorLit = null,
    },
};

/// A name from the file, with where it came from so a collision can be named.
pub const NamedColor = struct { name: []const u8, value: ColorEntry };

/// A value in `.vars`. Two shapes only: a number, or a string.
pub const VarValue = union(enum) {
    number: f64,
    text: []const u8,
};

pub const NamedVar = struct { name: []const u8, value: VarValue };

/// A reference, as written: `.accent` or `.text`. `value()` is the name without the dot.
pub const Ref = struct { name: []const u8 };

/// A style as READ, before resolution. Colours are `.name` references; `size` and `weight`
/// are a literal or a `.var` name, decided by the token kind.
pub const StyleFields = struct {
    color: ?Ref = null,
    bg: ?Ref = null,
    border: ?Ref = null,
    /// A quoted family name, or a `.var` that holds one.
    font: ?VarOr = null,
    size: ?VarOr = null,
    weight: ?VarOr = null,
    halo: ?Ref = null,
};

/// A literal or a name, decided by the token kind rather than by guessing: a number is a
/// number, `.name` is a reference.
pub const VarOr = union(enum) {
    literal: f64,
    name: []const u8,
    /// A quoted value written inline (a font family), owned by the tables.
    text: []const u8,
};

pub const NamedStyle = struct { name: []const u8, value: StyleSpec };
pub const NamedGradient = struct { name: []const u8, value: GradientLit };

pub const OpenTables = struct {
    colors: []NamedColor = &.{},
    gradients: []NamedGradient = &.{},
    vars: []NamedVar = &.{},
    styles: []NamedStyle = &.{},
};

/// Read `.colors` and `.gradients` from the token stream. Returns names owned by `gpa`.
/// Caller frees with `freeOpenTables`.
pub fn readOpenTables(gpa: Allocator, src: [:0]const u8, diag: *ThemeDiag) ThemeLoadError!OpenTables {
    var ast = std.zig.Ast.parse(gpa, src, .zon) catch return error.OutOfMemory;
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) {
        // The typed reader reports syntax errors with a better message; this
        // pass only needs to not crash. Let it through as empty.
        return .{};
    }
    var w = Walker{ .ast = &ast, .gpa = gpa, .diag = diag };
    return w.run();
}

const Walker = struct {
    ast: *std.zig.Ast,
    gpa: Allocator,
    /// Vars encountered so far, so a style can resolve `.weight` at read time.
    seen_vars: []const NamedVar = &.{},
    diag: *ThemeDiag,
    i: u32 = 0,

    fn tok(self: *Walker) std.zig.Token.Tag {
        return self.ast.tokens.items(.tag)[self.i];
    }
    fn slice(self: *Walker) []const u8 {
        return self.ast.tokenSlice(self.i);
    }
    fn advance(self: *Walker) void {
        if (self.i + 1 < self.ast.tokens.items(.tag).len) self.i += 1;
    }
    /// Skip one value, however deeply nested.
    fn skipValue(self: *Walker) void {
        var depth: usize = 0;
        while (self.i < self.ast.tokens.items(.tag).len) {
            switch (self.tok()) {
                .l_brace, .l_paren, .l_bracket => depth += 1,
                .r_brace, .r_paren, .r_bracket => {
                    depth -= 1;
                    if (depth == 0) {
                        self.advance();
                        return;
                    }
                },
                .comma => if (depth == 0) return,
                .eof => return,
                else => {},
            }
            self.advance();
        }
    }

    fn run(self: *Walker) ThemeLoadError!OpenTables {
        // errdefer runs in REVERSE order, so the buffer's deinit must be
        // declared FIRST -- otherwise the contents are freed after the list
        // that points at them has already been released.
        var colors: std.ArrayListUnmanaged(NamedColor) = .empty;
        errdefer colors.deinit(self.gpa);
        errdefer freeNamedColors(self.gpa, colors.items);
        var grads: std.ArrayListUnmanaged(NamedGradient) = .empty;
        errdefer grads.deinit(self.gpa);
        errdefer freeNamedGradients(self.gpa, grads.items);
        var vars_list: std.ArrayListUnmanaged(NamedVar) = .empty;
        errdefer vars_list.deinit(self.gpa);
        errdefer freeNamedVars(self.gpa, vars_list.items);
        var styles: std.ArrayListUnmanaged(NamedStyle) = .empty;
        errdefer styles.deinit(self.gpa);
        errdefer freeNamedStyles(self.gpa, styles.items);

        while (self.tok() != .eof) {
            // A top-level field is `.` `identifier` `=`
            if (self.tok() == .period and self.i + 2 < self.ast.tokens.items(.tag).len) {
                const name_tok = self.ast.tokens.items(.tag)[self.i + 1];
                if (name_tok == .identifier) {
                    const name = self.ast.tokenSlice(self.i + 1);
                    const eq = self.ast.tokens.items(.tag)[self.i + 2] == .equal;
                    if (eq) {
                        if (std.mem.eql(u8, name, "colors")) {
                            self.i += 3;
                            try self.readColors(&colors);
                            continue;
                        }
                        if (std.mem.eql(u8, name, "gradients")) {
                            self.i += 3;
                            try self.readGradients(&grads);
                            continue;
                        }
                        if (std.mem.eql(u8, name, "vars")) {
                            self.i += 3;
                            try self.readVars(&vars_list);
                            self.seen_vars = vars_list.items;
                            continue;
                        }
                        if (std.mem.eql(u8, name, "styles")) {
                            self.i += 3;
                            try self.readStyles(&styles);
                            continue;
                        }
                    }
                }
            }
            self.advance();
        }
        return .{
            .colors = try colors.toOwnedSlice(self.gpa),
            .gradients = try grads.toOwnedSlice(self.gpa),
            .vars = try vars_list.toOwnedSlice(self.gpa),
            .styles = try styles.toOwnedSlice(self.gpa),
        };
    }

    fn readColors(self: *Walker, out: *std.ArrayListUnmanaged(NamedColor)) ThemeLoadError!void {
        if (self.tok() != .period) return;
        self.advance(); // .
        if (self.tok() != .l_brace) return;
        self.advance(); // {
        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() == .period) {
                self.advance();
                if (self.tok() != .identifier) {
                    self.skipValue();
                    continue;
                }
                const name = self.slice();
                self.advance();
                if (self.tok() != .equal) {
                    self.skipValue();
                    continue;
                }
                self.advance();
                // A named entry that yields no value is an ERROR. Treating it as
                // "skip" is how `.bg = .nope` produced an empty colour table
                // with no diagnostic: the reader consumed the name, returned
                // null, and the loop moved on as if the entry were absent.
                const value = (try self.readColorEntry(name)) orelse {
                    self.diag.set(".{s} is not a colour", .{name});
                    return error.Palette;
                };
                if (self.dupeName(out.items, name)) |_|
                    return self.collision(name);
                const owned = try self.gpa.dupe(u8, name);
                out.append(self.gpa, .{ .name = owned, .value = value }) catch return error.OutOfMemory;
                continue;
            }
            self.advance();
        }
        self.advance(); // }
    }

    fn readGradients(self: *Walker, out: *std.ArrayListUnmanaged(NamedGradient)) ThemeLoadError!void {
        if (self.tok() != .period) return;
        self.advance();
        if (self.tok() != .l_brace) return;
        self.advance();
        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() == .period) {
                self.advance();
                if (self.tok() != .identifier) {
                    self.skipValue();
                    continue;
                }
                const name = self.slice();
                self.advance();
                if (self.tok() != .equal) {
                    self.skipValue();
                    continue;
                }
                self.advance();
                if (try self.readGradientLit(name)) |g| {
                    for (out.items) |e| if (std.mem.eql(u8, e.name, name)) return self.collision(name);
                    const owned = try self.gpa.dupe(u8, name);
                    out.append(self.gpa, .{ .name = owned, .value = g }) catch return error.OutOfMemory;
                }
                continue;
            }
            self.advance();
        }
        self.advance();
    }

    /// `.vars = .{ .weight = 600, .latin_font = "Roboto Flex" }`. Only numbers and strings,
    /// and the shape decides which -- never a guess.
    fn readVars(self: *Walker, out: *std.ArrayListUnmanaged(NamedVar)) ThemeLoadError!void {
        if (self.tok() != .period) return;
        self.advance();
        if (self.tok() != .l_brace) return;
        self.advance();
        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() != .period) {
                self.advance();
                continue;
            }
            self.advance();
            if (self.tok() != .identifier) {
                self.skipValue();
                continue;
            }
            const name = self.slice();
            self.advance();
            if (self.tok() != .equal) {
                self.skipValue();
                continue;
            }
            self.advance();

            const value: VarValue = switch (self.tok()) {
                .number_literal => blk: {
                    const n = std.fmt.parseFloat(f64, self.slice()) catch {
                        self.diag.set("var \"{s}\" is not a number", .{name});
                        return error.Palette;
                    };
                    self.advance();
                    break :blk .{ .number = n };
                },
                .string_literal => blk: {
                    const raw = self.slice();
                    self.advance();
                    break :blk .{ .text = try self.gpa.dupe(u8, trimQuotes(raw)) };
                },
                else => {
                    self.diag.set("var \"{s}\" must be a number or a string", .{name});
                    return error.Palette;
                },
            };
            for (out.items) |e| if (std.mem.eql(u8, e.name, name)) return self.collision(name);
            out.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .value = value }) catch return error.OutOfMemory;
        }
        self.advance(); // }
    }

    /// `.styles = .{ .latin = .{ .color = .accent, .weight = .weight } }`.
    fn readStyles(self: *Walker, out: *std.ArrayListUnmanaged(NamedStyle)) ThemeLoadError!void {
        if (self.tok() != .period) return;
        self.advance();
        if (self.tok() != .l_brace) return;
        self.advance();
        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() != .period) {
                self.advance();
                continue;
            }
            self.advance();
            if (self.tok() != .identifier) {
                self.skipValue();
                continue;
            }
            const name = self.slice();
            self.advance();
            if (self.tok() != .equal) {
                self.skipValue();
                continue;
            }
            self.advance();
            if (self.tok() != .period or !self.nextIsBrace()) {
                self.skipValue();
                continue;
            }
            self.advance(); // .
            self.advance(); // {

            var entry: StyleSpec = .{};
            while (self.tok() != .r_brace and self.tok() != .eof) {
                if (self.tok() != .period) {
                    self.advance();
                    continue;
                }
                self.advance();
                if (self.tok() != .identifier) {
                    self.skipValue();
                    continue;
                }
                const key = self.slice();
                self.advance();
                if (self.tok() != .equal) {
                    self.skipValue();
                    continue;
                }
                self.advance();
                try self.readStyleField(&entry, key);
            }
            self.advance(); // }

            for (out.items) |e| if (std.mem.eql(u8, e.name, name)) return self.collision(name);
            out.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .value = entry }) catch return error.OutOfMemory;
        }
        self.advance(); // }
    }

    fn readStyleField(self: *Walker, entry: *StyleSpec, key: []const u8) ThemeLoadError!void {
        // Colours and gradients arrive as `.name`; the resolver downstream
        // takes the name WITHOUT the dot, so the conversion happens here and
        // StyleSpec keeps its existing string shape.
        if (std.mem.eql(u8, key, "color") or std.mem.eql(u8, key, "bg") or
            std.mem.eql(u8, key, "border"))
        {
            const ref = try self.readRef() orelse {
                self.diag.set("style .{s} must be a reference like .accent", .{key});
                return error.Palette;
            };
            const owned = try self.gpa.dupe(u8, ref.name);
            if (std.mem.eql(u8, key, "color")) entry.color = owned else if (std.mem.eql(u8, key, "bg")) entry.bg = owned else entry.border = owned;
            return;
        }
        if (std.mem.eql(u8, key, "font")) {
            switch (self.tok()) {
                .string_literal => {
                    const owned = try self.gpa.dupe(u8, trimQuotes(self.slice()));
                    entry.font = owned;
                    self.advance();
                },
                .period => {
                    const r = try self.readRef() orelse {
                        self.diag.set("style .font must be a name or a .var", .{});
                        return error.Palette;
                    };
                    // A `.var` naming a font resolves to the family NOW. A name
                    // that is missing or holds a number is an error, not a
                    // literal -- otherwise the file would render "latin_font".
                    const family = self.varText(r.name) orelse {
                        self.diag.set("style .font names .{s}, which is not a text var", .{r.name});
                        return error.Palette;
                    };
                    entry.font = try self.gpa.dupe(u8, family);
                },
                else => {
                    self.diag.set("style .font must be a name or a .var", .{});
                    return error.Palette;
                },
            }
            return;
        }
        if (std.mem.eql(u8, key, "size") or std.mem.eql(u8, key, "weight")) {
            const n: f32 = switch (self.tok()) {
                .number_literal => blk: {
                    const v = std.fmt.parseFloat(f32, self.slice()) catch {
                        self.diag.set("style .{s} is not a number", .{key});
                        return error.Palette;
                    };
                    self.advance();
                    break :blk v;
                },
                .period => blk: {
                    const r = try self.readRef() orelse {
                        self.diag.set("style .{s} must be a number or a .var", .{key});
                        return error.Palette;
                    };
                    // A `.var` is resolved at READ time against what has been
                    // seen so far; a name that is not there is an error, not a
                    // silent default.
                    break :blk self.varNumber(r.name) orelse {
                        self.diag.set("style .{s} names .{s}, which is not a number var", .{ key, r.name });
                        return error.Palette;
                    };
                },
                else => {
                    self.diag.set("style .{s} must be a number or a .var", .{key});
                    return error.Palette;
                },
            };
            if (std.mem.eql(u8, key, "size")) entry.size = n else entry.weight = @intFromFloat(n);
            return;
        }
        if (std.mem.eql(u8, key, "frost")) {
            entry.frost = (try self.readFrost()) orelse {
                self.diag.set("style .frost must be a struct of frost fields", .{});
                return error.Palette;
            };
            return;
        }
        if (std.mem.eql(u8, key, "stroke")) {
            entry.stroke = try self.readWidth("style .stroke");
            return;
        }
        if (std.mem.eql(u8, key, "halo")) {
            // Dropped silently before this branch existed: the field is in
            // `StyleSpec`, `copyStyles`, `styleView` and `styleByName`, so a
            // halo parsed nowhere looked like a style that simply had none.
            // The symptom was an element that emitted no halo prim at all.
            entry.halo = (try self.readHalo()) orelse {
                self.diag.set("style .halo must be a struct of halo fields", .{});
                return error.Palette;
            };
            return;
        }
        self.skipValue();
    }

    /// `.{ .blur = 12 }` -- a frost has one field.
    fn readFrost(self: *Walker) ThemeLoadError!?FrostSpec {
        if (self.tok() != .period or !self.nextIsBrace()) return null;
        self.advance(); // .
        self.advance(); // {
        var out: FrostSpec = .{};
        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() != .period) {
                self.advance();
                continue;
            }
            self.advance();
            if (self.tok() != .identifier) {
                self.skipValue();
                continue;
            }
            const key = self.slice();
            self.advance();
            if (self.tok() != .equal) {
                self.skipValue();
                continue;
            }
            self.advance();
            if (std.mem.eql(u8, key, "blur")) {
                out.blur = try self.readNumber("frost .blur");
            } else {
                self.diag.set("frost names .{s}, which is not a frost field", .{key});
                return error.Palette;
            }
        }
        self.advance(); // }
        return out;
    }

    /// A bare `true` or `false`.
    fn readBool(self: *Walker, what: []const u8) bool {
        if (self.tok() == .identifier) {
            const v = self.slice();
            if (std.mem.eql(u8, v, "true")) {
                self.advance();
                return true;
            }
            if (std.mem.eql(u8, v, "false")) {
                self.advance();
                return false;
            }
        }
        self.diag.set("{s} must be true or false", .{what});
        return false;
    }

    /// A stroke width: absent, or 1..255 pixels. `false` is what the field used
    /// to be, so it still reads as absent -- an old theme that wrote
    /// `.stroke = true` gets a 1px outline rather than an error.
    fn readWidth(self: *Walker, what: []const u8) ThemeLoadError!?u8 {
        if (self.tok() == .identifier) {
            const v = self.slice();
            if (std.mem.eql(u8, v, "false")) {
                self.advance();
                return null;
            }
            if (std.mem.eql(u8, v, "true")) {
                self.advance();
                return 1;
            }
        }
        const n = try self.readNumber(what);
        if (n < 1 or n > 255 or @floor(n) != n) {
            self.diag.set("{s} must be a width from 1 to 255", .{what});
            return error.Palette;
        }
        return @intFromFloat(n);
    }

    /// `.{ .color = .accent, .blur = 8, .mode = .outer_glow, .offset = .{ 2, 4 } }` Every
    /// field is optional and defaults to `HaloSpec`.
    fn readHalo(self: *Walker) ThemeLoadError!?HaloSpec {
        if (self.tok() != .period or !self.nextIsBrace()) return null;
        self.advance(); // .
        self.advance(); // {

        var out: HaloSpec = .{};

        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() != .period) {
                self.advance();
                continue;
            }
            self.advance();
            if (self.tok() != .identifier) {
                self.skipValue();
                continue;
            }
            const key = self.slice();
            self.advance();
            if (self.tok() != .equal) {
                self.skipValue();
                continue;
            }
            self.advance();

            if (std.mem.eql(u8, key, "color")) {
                const r = try self.readRef() orelse {
                    self.diag.set("halo .color must be a role like .accent", .{});
                    return error.Palette;
                };
                out.color = try self.gpa.dupe(u8, r.name);
            } else if (std.mem.eql(u8, key, "blur")) {
                out.blur = try self.readNumber("halo .blur");
            } else if (std.mem.eql(u8, key, "spread")) {
                out.spread = try self.readNumber("halo .spread");
            } else if (std.mem.eql(u8, key, "light")) {
                out.light = try self.readNumber("halo .light");
            } else if (std.mem.eql(u8, key, "offset")) {
                out.offset = try self.readNumberPair("halo .offset");
            } else if (std.mem.eql(u8, key, "mode")) {
                const r = try self.readRef() orelse {
                    self.diag.set("halo .mode must be .glow, .outer_glow or .inner_glow", .{});
                    return error.Palette;
                };
                out.mode = std.meta.stringToEnum(elmz.Halo.Mode, r.name) orelse {
                    self.diag.set("halo .mode \"{s}\" is not glow, outer_glow or inner_glow", .{r.name});
                    return error.Palette;
                };
            } else if (std.mem.eql(u8, key, "quality")) {
                const r = try self.readRef() orelse {
                    self.diag.set("halo .quality must be .baked or .sdf", .{});
                    return error.Palette;
                };
                out.quality = std.meta.stringToEnum(elmz.Halo.Quality, r.name) orelse {
                    self.diag.set("halo .quality \"{s}\" is not baked or sdf", .{r.name});
                    return error.Palette;
                };
            } else {
                // An unknown halo key is a typo inside a table the file itself
                // opened, not a new named thing: `.blurr = 8` would otherwise
                // leave a halo at the default blur and say nothing.
                self.diag.set("halo names .{s}, which is not a halo field", .{key});
                return error.Palette;
            }
        }
        self.advance(); // }
        return out;
    }

    /// A bare number. Rejects a `.var` here on purpose: every halo field is geometry, and a
    /// var that held text would silently become 0.
    fn readNumber(self: *Walker, what: []const u8) ThemeLoadError!f32 {
        if (self.tok() != .number_literal) {
            self.diag.set("{s} must be a number", .{what});
            return error.Palette;
        }
        const v = std.fmt.parseFloat(f32, self.slice()) catch {
            self.diag.set("{s} is not a number", .{what});
            return error.Palette;
        };
        self.advance();
        return v;
    }

    /// `.{ 2, 4 }` -- an offset pair.
    fn readNumberPair(self: *Walker, what: []const u8) ThemeLoadError![2]f32 {
        if (self.tok() != .period) {
            self.diag.set("{s} must be .{{ x, y }}", .{what});
            return error.Palette;
        }
        self.advance(); // .
        if (self.tok() != .l_brace) {
            self.diag.set("{s} must be .{{ x, y }}", .{what});
            return error.Palette;
        }
        self.advance(); // {
        var pair: [2]f32 = .{ 0, 0 };
        var n: usize = 0;
        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() == .number_literal) {
                if (n < 2) {
                    pair[n] = std.fmt.parseFloat(f32, self.slice()) catch {
                        self.diag.set("{s} is not a number", .{what});
                        return error.Palette;
                    };
                    n += 1;
                }
            }
            self.advance();
        }
        if (self.tok() != .r_brace or n != 2) {
            self.diag.set("{s} must be exactly two numbers", .{what});
            return error.Palette;
        }
        self.advance(); // }
        return pair;
    }

    /// The number a `.var` names, or null if it is missing or not a number.
    fn varNumber(self: *Walker, name: []const u8) ?f32 {
        for (self.seen_vars) |v| {
            if (std.mem.eql(u8, v.name, name)) return switch (v.value) {
                .number => |n| @floatCast(n),
                .text => null,
            };
        }
        return null;
    }

    /// The text a `.var` names, or null if it is missing or not text.
    fn varText(self: *Walker, name: []const u8) ?[]const u8 {
        for (self.seen_vars) |v| {
            if (std.mem.eql(u8, v.name, name)) return switch (v.value) {
                .text => |t| t,
                .number => null,
            };
        }
        return null;
    }

    /// True when the token AFTER the current one is `{`. Used to tell `.{` (a struct) from
    /// a bare `.name` reference without consuming anything.
    fn nextIsBrace(self: *Walker) bool {
        const tags = self.ast.tokens.items(.tag);
        return self.i + 1 < tags.len and tags[self.i + 1] == .l_brace;
    }

    /// `.name` -> Ref. Returns null and leaves the cursor put if it is not one.
    fn readRef(self: *Walker) ThemeLoadError!?Ref {
        if (self.tok() != .period) return null;
        const save = self.i;
        self.advance();
        if (self.tok() != .identifier) {
            self.i = save;
            return null;
        }
        const name = self.slice();
        self.advance();
        return .{ .name = name };
    }

    fn dupeName(self: *Walker, have: []const NamedColor, name: []const u8) ?void {
        _ = self;
        for (have) |e| if (std.mem.eql(u8, e.name, name)) return {};
        return null;
    }

    fn collision(self: *Walker, name: []const u8) ThemeLoadError {
        self.diag.set("name \"{s}\" is defined twice", .{name});
        return error.Palette;
    }

    fn readColorEntry(self: *Walker, name: []const u8) ThemeLoadError!?ColorEntry {
        // A gradient is a container whose first field is a known tag.
        if (self.tok() == .period) {
            const save = self.i;
            self.advance();
            if (self.tok() == .l_brace) {
                self.advance();
                if (self.tok() == .period) {
                    self.advance();
                    if (self.tok() == .identifier) {
                        const tag = self.slice();
                        if (std.mem.eql(u8, tag, "linear") or std.mem.eql(u8, tag, "radial")) {
                            self.i = save;
                            if (try self.readGradientLit(name)) |g| return .{ .gradient = g };
                            return null;
                        }
                    }
                }
            }
            // Restore unconditionally. The probe above advanced past `.{`
            // looking for a gradient tag; an array colour has the same opening
            // and no tag, and `readColorLit` needs to see the token from the
            // start. Restoring only on the tag branch left the reader mid-value,
            // so `.{ 10, 20 }` produced no colour AND no diagnostic -- the
            // entry vanished with the error swallowed upstream.
            self.i = save;
        }
        if (try self.readColorLit(name)) |c| return .{ .solid = c };
        return null;
    }

    fn readColorLit(self: *Walker, name: []const u8) ThemeLoadError!?ColorLit {
        // A ZON array is written `.{ ... }`, never `{ ... }` -- consume the
        // dot so the `.{ 200, 200, 20 }` spelling reaches the brace branch.
        if (self.tok() == .period) {
            self.advance();
            if (self.tok() != .l_brace) return null;
        }
        switch (self.tok()) {
            .number_literal => {
                const hex = std.fmt.parseInt(u32, self.slice(), 0) catch {
                    self.diag.set("{s}: .{s} is not a number", .{ "theme.zon", name });
                    return error.Palette;
                };
                self.advance();
                return .{ .hex = hex };
            },
            .l_brace => {
                self.advance();
                var nums: [4]f64 = .{ 0, 0, 0, 255 };
                var n: usize = 0;
                while (self.tok() != .r_brace and self.tok() != .eof) {
                    if (self.tok() == .number_literal and n < 4) {
                        nums[n] = std.fmt.parseFloat(f64, self.slice()) catch {
                            self.diag.set(".{s} has a value that is not a number", .{name});
                            return error.Palette;
                        };
                        n += 1;
                    }
                    self.advance();
                }
                self.advance(); // }
                if (n != 3 and n != 4) {
                    self.diag.set(".{s} needs 3 or 4 numbers, found {d}", .{ name, n });
                    return error.Palette;
                }

                // Magnitude decides the scale, on the WHOLE array: all <= 1.0
                // is a fraction, any > 1.0 is an 0-255 channel. A mixed array
                // has no reading that matches what the author meant, so it is
                // an error rather than a guess.
                var all_le_one = true;
                var any_gt_one = false;
                for (nums[0..n]) |c| {
                    if (c < 0) {
                        self.diag.set(".{s} has a negative channel", .{name});
                        return error.Palette;
                    }
                    if (c > 1.0) {
                        all_le_one = false;
                        any_gt_one = true;
                    }
                }
                var vals: [4]u8 = .{ 0, 0, 0, 255 };
                for (nums[0..n], 0..) |c, k| {
                    // Range FIRST, convert second. `@intFromFloat` on a
                    // negative panics in debug rather than clamping, so the
                    // check has to run on the float, not on the result.
                    const scaled = if (all_le_one) @round(c * 255.0) else @round(c);
                    if (!std.math.isFinite(scaled) or scaled < 0 or scaled > 255) {
                        self.diag.set(".{s} channel {d} is out of range", .{ name, c });
                        return error.Palette;
                    }
                    vals[k] = @intFromFloat(scaled);
                }
                return switch (n) {
                    3 => .{ .rgb = .{ vals[0], vals[1], vals[2] } },
                    4 => .{ .rgba = vals },
                    else => unreachable,
                };
            },
            else => return null,
        }
    }

    fn readGradientLit(self: *Walker, name: []const u8) ThemeLoadError!?GradientLit {
        _ = name;
        if (self.tok() != .period) return null;
        self.advance();
        if (self.tok() != .l_brace) return null;
        self.advance();
        if (self.tok() != .period) {
            self.skipValue();
            return null;
        }
        self.advance();
        if (self.tok() != .identifier) return null;
        const tag = self.slice();
        const is_linear = std.mem.eql(u8, tag, "linear");
        const is_radial = std.mem.eql(u8, tag, "radial");
        if (!is_linear and !is_radial) {
            self.skipValue();
            return null;
        }
        self.advance();
        if (self.tok() != .equal) return null;
        self.advance();
        if (self.tok() != .period) return null;
        self.advance();
        if (self.tok() != .l_brace) return null;
        self.advance();

        var lin: @TypeOf(@as(GradientLit, undefined).linear) = .{};
        var rad: @TypeOf(@as(GradientLit, undefined).radial) = .{};

        while (self.tok() != .r_brace and self.tok() != .eof) {
            if (self.tok() == .period) {
                self.advance();
                if (self.tok() != .identifier) {
                    self.skipValue();
                    continue;
                }
                const key = self.slice();
                self.advance();
                if (self.tok() != .equal) {
                    self.skipValue();
                    continue;
                }
                self.advance();
                if (std.mem.eql(u8, key, "dir")) {
                    if (self.tok() == .number_literal) {
                        lin.dir = std.fmt.parseFloat(f32, self.slice()) catch lin.dir;
                        self.advance();
                    } else self.skipValue();
                } else if (std.mem.eql(u8, key, "radius")) {
                    if (self.tok() == .number_literal) {
                        rad.radius = std.fmt.parseFloat(f32, self.slice()) catch rad.radius;
                        self.advance();
                    } else self.skipValue();
                } else if (std.mem.eql(u8, key, "center")) {
                    if (self.tok() == .period) {
                        self.advance();
                        if (self.tok() == .l_brace) {
                            self.advance();
                            var vals: [2]f32 = .{ 0.5, 0.5 };
                            var n: usize = 0;
                            while (self.tok() != .r_brace and self.tok() != .eof) {
                                if (self.tok() == .number_literal and n < 2) {
                                    vals[n] = std.fmt.parseFloat(f32, self.slice()) catch 0;
                                    n += 1;
                                }
                                self.advance();
                            }
                            self.advance();
                            if (n == 2) rad.center = vals;
                        }
                    }
                } else if (std.mem.eql(u8, key, "from")) {
                    lin.from = try self.readColorLit(key);
                } else if (std.mem.eql(u8, key, "to")) {
                    lin.to = try self.readColorLit(key);
                } else if (std.mem.eql(u8, key, "inner")) {
                    rad.inner = try self.readColorLit(key);
                } else if (std.mem.eql(u8, key, "outer")) {
                    rad.outer = try self.readColorLit(key);
                } else {
                    self.skipValue();
                }
                continue;
            }
            self.advance();
        }
        self.advance(); // close the spec `.{ ... }`
        // Consume the gradient's own closing brace so the caller's loop sees
        // the comma after it, not a `}` that ends the table.
        if (self.tok() == .r_brace) self.advance();
        return if (is_linear) .{ .linear = lin } else .{ .radial = rad };
    }
};

/// A string literal's token includes its quotes; the value is what is inside.
fn trimQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
    return raw;
}

fn freeNamedColors(gpa: Allocator, items: []NamedColor) void {
    for (items) |e| gpa.free(e.name);
}
fn freeNamedGradients(gpa: Allocator, items: []NamedGradient) void {
    for (items) |e| gpa.free(e.name);
}
fn freeNamedVars(gpa: Allocator, items: []NamedVar) void {
    for (items) |e| {
        gpa.free(e.name);
        switch (e.value) {
            .text => |t| gpa.free(t),
            else => {},
        }
    }
}
fn freeNamedStyles(gpa: Allocator, items: []NamedStyle) void {
    for (items) |e| {
        gpa.free(e.name);
        if (e.value.font) |f| gpa.free(f);
        if (e.value.color) |c| gpa.free(c);
        if (e.value.bg) |c| gpa.free(c);
        if (e.value.border) |c| gpa.free(c);
        // The halo's colour is a role NAME this walker duped, exactly like the
        // four above. Leaving it out leaked one allocation per styled halo.
        if (e.value.halo) |h| gpa.free(h.color);
    }
}
pub fn freeOpenTables(gpa: Allocator, t: *OpenTables) void {
    freeNamedColors(gpa, t.colors);
    freeNamedGradients(gpa, t.gradients);
    freeNamedVars(gpa, t.vars);
    freeNamedStyles(gpa, t.styles);
    gpa.free(t.colors);
    gpa.free(t.gradients);
    gpa.free(t.vars);
    gpa.free(t.styles);
    t.* = .{};
}

/// Is `ref` one of the palette's role names?
fn isRole(ref: []const u8, extra: []const Theme.CustomColor) bool {
    inline for (@typeInfo(ColorsSpec).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "roles")) continue;
        if (std.mem.eql(u8, ref, f.name)) return true;
    }
    for (extra) |c| if (std.mem.eql(u8, c.name, ref)) return true;
    return false;
}

/// A name the file gave a `.gradients` entry.
fn isGradientName(
    ref: []const u8,
    grads: []const CustomGradient,
) bool {
    for (grads) |g| if (std.mem.eql(u8, g.name, ref)) return true;
    return false;
}

fn styleNamed(styles: []const StyleEntry, n: []const u8) ?StyleEntry {
    for (styles) |e| if (std.mem.eql(u8, e.name, n)) return e;
    return null;
}

/// A style may name another style as its font. That is a graph, so a cycle is reachable,
/// and a cycle would be an infinite resolve at paint time.
fn checkStyleCycles(diag: *ThemeDiag, name: []const u8, styles: []const StyleEntry) ThemeLoadError!void {
    for (styles) |start| {
        var cur = start;
        var hops: usize = 0;
        while (true) {
            const next = cur.fontRef() orelse break;
            // A font name that matches no style is a typeface and resolves to
            // the registry. Only style-to-style edges can cycle.
            const nxt = styleNamed(styles, next) orelse break;
            hops += 1;
            if (hops > styles.len) {
                diag.set("{s}: style .{s} refers to itself through .font", .{ name, start.name });
                return error.Style;
            }
            cur = nxt;
        }
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "the palette guard is family-scoped" {
    try checkPalette(.{});

    var alias = Theme{};
    alias.border = alias.text_muted;
    try checkPalette(alias);

    var alias2 = Theme{};
    alias2.border = alias2.accent;
    try checkPalette(alias2);

    var bad = Theme{};
    bad.pressed = bad.hover;
    try std.testing.expectError(error.DuplicateRole, checkPalette(bad));

    var flat = Theme{};
    flat.text_muted = flat.text;
    try std.testing.expectError(error.DuplicateRole, checkPalette(flat));

    var flat_page = Theme{};
    flat_page.panel = flat_page.bg;
    try std.testing.expectError(error.DuplicateRole, checkPalette(flat_page));

    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "custom")) continue;
        try std.testing.expect(familyOf(f.name) != null);
    }
}

test "the shipped defaults list every role" {
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(struct {}, std.testing.allocator, "theme.defaults.zon", defaults_zon, Theme{}, &diag);
    defer freeStyles(std.testing.allocator, &loaded.styles);

    // A role added to `Theme` and forgotten in the file would leave the
    // compiled literal showing through, which is the one way the file stops
    // being the source of default values.
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "custom")) continue;
        try std.testing.expect(@hasField(ColorsSpec, f.name));
        try std.testing.expect(@hasField(GradientsSpec, f.name));
    }

    // The file ships no gradients: a default gradient would be a look, and the
    // library's default look is a flat palette.
    try std.testing.expect(!loaded.gradients.any());
}

test "the shipped defaults resolve to the compiled palette" {
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(struct {}, std.testing.allocator, "theme.defaults.zon", defaults_zon, Theme{}, &diag);
    defer freeStyles(std.testing.allocator, &loaded.styles);
    try std.testing.expect(std.meta.eql(@as(Theme, .{}), loaded.theme));
}

test "a gradient resolves to the fill a theme could never express before" {
    const src =
        \\.{ .version = 3, .theme = .{ .gradients = .{
        \\    .accent = .{ .linear = .{ .dir = 135, .from = 0x89b4fa, .to = 0xf5c2e7 } },
        \\    .panel = .{ .radial = .{ .inner = 0x313244, .outer = 0x1e1e2e, .radius = 0.75 } },
        \\} } }
    ;
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);

    const accent = loaded.gradients.accent.?;
    try std.testing.expectEqual(elmz.Fill.linear, std.meta.activeTag(accent));
    // 135 degrees is down-and-right, and the vector is unit length centred on
    // the box -- so it ends inside the box rather than at a corner. Comparing
    // against the shared helper keeps this honest if the mapping ever changes.
    try std.testing.expect(std.meta.eql(
        accent,
        elmz.Fill.angled(135, Color.rgbHex(0x89b4fa), Color.rgbHex(0xf5c2e7)),
    ));
    try std.testing.expect(accent.linear.to[1] > 0.8);

    const panel = loaded.gradients.panel.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), panel.radial.radius, 0.0001);

    // The colour roles are untouched: a gradient for `accent` does not silently
    // restate `accent`, so the solid palette and its guard stay meaningful.
    try std.testing.expect(std.meta.eql((Theme{}).accent, loaded.theme.accent));

    // And lookup by role name works, so an app need not know the shape.
    try std.testing.expect(loaded.gradients.get("accent") != null);
    try std.testing.expect(loaded.gradients.get("nothing") == null);
}

test "a linear direction is an angle, and it spans the box at any angle" {
    // The point of the float: 0, 45 and 90 used to be the only reachable
    // angles, so 22 degrees was simply not expressible.
    const case = struct {
        fn load(src: [:0]const u8) !elmz.Fill {
            var diag: ThemeDiag = .{};
            const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
            return loaded.gradients.bg.?;
        }
    };

    // 90 degrees runs left to right, exactly on the horizontal centre line.
    const h = (try case.load(
        \\.{ .version = 3, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = 90, .from = 0xff0000, .to = 0x0000ff } } } } }
    )).linear;
    try std.testing.expectApproxEqAbs(@as(f32, 0), h.from[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.to[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), h.from[1], 1e-6);

    // 180 runs top to bottom -- clock 6, what the old `vertical` default meant.
    const v = (try case.load(
        \\.{ .version = 3, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = 180, .from = 0xff0000, .to = 0x0000ff } } } } }
    )).linear;
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.from[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), v.to[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), v.from[0], 1e-6);

    // An angle the enum could not name still spans the whole box: the delta is
    // a unit vector, so turning the ramp never shrinks it.
    const a = (try case.load(
        \\.{ .version = 3, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = 22, .from = 0xff0000, .to = 0x0000ff } } } } }
    )).linear;
    const dx = a.to[0] - a.from[0];
    const dy = a.to[1] - a.from[1];
    try std.testing.expectApproxEqAbs(@as(f32, 1), @sqrt(dx * dx + dy * dy), 1e-6);
    // Clock 22 is up and slightly to the right, so dx stays small and dy is
    // negative -- the second half is what the old "to the right" sense had
    // backwards, so this assertion would fail against a half-migrated helper.
    try std.testing.expect(dx > 0.3 and dx < 0.4 and dy < -0.9);
}

test "a radial centre is a fraction of the box, not a pixel" {
    var diag: ThemeDiag = .{};
    const src =
        \\.{ .version = 3, .theme = .{ .gradients = .{
        \\    .panel = .{ .radial = .{ .inner = 0xffffff, .outer = 0x000000, .center = .{ 0, 0 }, .radius = 0.6 } },
        \\} } }
    ;
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    const f = loaded.gradients.panel.?;
    try std.testing.expectEqual(@as(f32, 0), f.radial.center[0]);
    try std.testing.expectEqual(@as(f32, 0), f.radial.center[1]);
    try std.testing.expectEqual(@as(f32, 0.6), f.radial.radius);

    // Omitted centre keeps the middle, so an old file renders as it did.
    var diag2: ThemeDiag = .{};
    const mid = try loadTheme(struct {}, std.testing.allocator, "theme.zon",
        \\.{ .version = 3, .theme = .{ .gradients = .{ .panel = .{ .radial = .{} } } } }
    , Theme{}, &diag2);
    try std.testing.expectEqual(@as(f32, 0.5), mid.gradients.panel.?.radial.center[0]);
}

test "a theme file cannot compute anything" {
    // The values-only property, stated where a regression would be caught: a
    // theme file that tried to call or import would be rejected by the parser
    // before any of our code runs.
    const cases = [_][:0]const u8{
        ".{ .version = 3, .theme = .{ .colors = .{ .bg = 1 + 1 } } }",
        ".{ .version = 3, .theme = .{ .colors = .{ .bg = @import(\"std\") } } }",
        ".{ .version = 3, .theme = .{ .colors = .{ .bg = compute() } } }",
    };
    for (cases) |src| {
        var diag: ThemeDiag = .{};
        try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    }
}

test "an unknown key in .colors becomes a custom role" {
    // Deliberately NOT an error. The file may invent role names, and rejecting
    // an unused one would cost a band over something harmless. A role nothing
    // references is a warning-shaped concern at most, and not one being paid
    // for right now.
    const src = ".{ .version = 3, .theme = .{ .colors = .{ .bgx = 0xff0000 } } }";
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    defer freeCustom(std.testing.allocator, &loaded.theme);
    defer freeStyles(std.testing.allocator, &loaded.styles);
    try std.testing.expectEqual(@as(usize, 1), loaded.theme.custom.len);
    try std.testing.expectEqualStrings("bgx", loaded.theme.custom[0].name);
}

test "the palette guard names the offending pair" {
    var bad = Theme{};
    bad.hover = bad.control;
    try std.testing.expectEqual(error.DuplicateRole, checkPalette(bad) catch |e| e);

    const c = firstCollision(bad).?;
    try std.testing.expectEqual(RoleFamily.interaction, c.family);
    try std.testing.expectEqualStrings("control", c.a);
    try std.testing.expectEqualStrings("hover", c.b);

    try std.testing.expect(firstCollision(.{}) == null);
}

test "a custom colour is a role, not a parse-only name" {
    // The whole point of the v3 `.colors` tier, and the failure it invites: a
    // name that parses, resolves to nothing, and paints the `text` fallback --
    // a REAL colour, so nothing looks broken, the label just draws wrong. So
    // this asserts the hex arrives, and that a style may reference it.
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    const src =
        \\.{ .version = 3,
        \\   .theme = .{ .colors = .{
        \\       .bg = 0x101010,
        \\       .danger = 0xeba0ac,
        \\   } },
        \\   .styles = .{ .warn = .{ .bg = .danger } },
        \\}
    ;
    var loaded = try loadTheme(struct {}, gpa, "custom.zon", src, .{}, &diag);
    defer freeStyles(gpa, &loaded.styles);
    defer freeCustom(gpa, &loaded.theme);

    try std.testing.expectEqual(@as(usize, 1), loaded.theme.custom.len);
    try std.testing.expectEqualStrings("danger", loaded.theme.custom[0].name);
    try std.testing.expect(std.meta.eql(loaded.theme.custom[0].color, elmz.Color.rgbHex(0xeba0ac)));

    // Through the accessor widgets actually use, and NOT the fallback.
    try std.testing.expect(std.meta.eql(elmz.roleColor(loaded.theme, "danger"), elmz.Color.rgbHex(0xeba0ac)));
    try std.testing.expect(!std.meta.eql(elmz.roleColor(loaded.theme, "danger"), loaded.theme.text));

    // A style may name it. Before `isRole` knew about the side table this file
    // was rejected outright.
    try std.testing.expectEqual(@as(usize, 1), loaded.styles.len);

    // The custom name is DUPED, not borrowed: the parse result is freed on
    // return, so a borrowed slice would dangle. Reading it here after the free
    // is the observation that proves it.
    try std.testing.expectEqualStrings("danger", loaded.theme.custom[0].name);
}

test "a Ui with no theme file still resolves the built-in styles" {
    // The failure this prevents: `styles` was null until a file supplied one,
    // so a bare Ui could not find `heading`, and every scripted label fell to
    // the primary face -- tofu for Arabic and CJK, with nothing reporting why.
    const M = void;
    var ui: elmz.Ui(M) = .init(std.testing.allocator);
    defer ui.deinit();

    try std.testing.expect(ui.styleByName("heading") != null);
    try std.testing.expect(ui.styleByName("card") != null);
    for ([_][]const u8{ "latin", "arabic", "thai", "chinese", "japanese", "korean" }) |n| {
        try std.testing.expect(ui.styleByName(n) != null);
    }
    try std.testing.expect(ui.styleByName("nope") == null);
}

test "colour values: every free-form spelling" {
    const cases = [_]struct { src: []const u8, want: u32 }{
        .{ .src = "0x1e1e2e", .want = 0x1e1e2eff },
        .{ .src = "0xffeeddcc", .want = 0xffeeddcc },
        .{ .src = ".{ 200, 200, 20 }", .want = 0xc8c814ff },
        .{ .src = ".{ 200, 200, 20, 128 }", .want = 0xc8c81480 },
        .{ .src = ".{ 200.0, 200.0, 20.0 }", .want = 0xc8c814ff },
        .{ .src = ".{ 1.0, 0.5, 0.0 }", .want = 0xff8000ff },
        .{ .src = ".{ 1.0, 1.0, 1.0 }", .want = 0xffffffff },
        .{ .src = ".{ 0.0, 0.0, 0.0, 1.0 }", .want = 0x000000ff },
    };
    const gpa = std.testing.allocator;
    inline for (cases) |c| {
        var ast = try std.zig.Ast.parse(gpa, c.src ++ "", .zon);
        defer ast.deinit(gpa);
        var zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
        defer zoir.deinit(gpa);
        const got = try ColorValue.read(ast, zoir, .root);
        try std.testing.expectEqual(c.want, @as(u32, got.r) << 24 | @as(u32, got.g) << 16 | @as(u32, got.b) << 8 | got.a);
    }
}

test "colour values: mixed floats are refused, not guessed" {
    const gpa = std.testing.allocator;
    var ast = try std.zig.Ast.parse(gpa, ".{ 1.0, 0.5, 200 }" ++ "", .zon);
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(gpa);
    try std.testing.expectError(error.ColourMixedFloats, ColorValue.read(ast, zoir, .root));
}

const user_file_src =
    \\.{
    \\    .version = 3,
    \\    .theme = .{
    \\        .colors = .{
    \\            .bg = 0x1e1e2e78,
    \\            .panel = .{128,128,128},
    \\            .border = .{200,200,20,167},
    \\            .text = .{ 0.6,0.5,0.4,0.3 },
    \\        },
    \\        .gradients = .{
    \\            .accent = .{ .linear = .{ .dir = 135, .to = 0xf3c0e5 } },
    \\            .gradient1 = .{ .radial = .{ .inner = 0x77475a, .center = .{ 0.25, 0.15 }, .radius = 0.7 } },
    \\        },
    \\        .vars = .{ .weight = 600, .latin_font = "Roboto Flex" },
    \\        .styles = .{
    \\            .latin = .{ .color = .accent, .font = .latin_font, .weight = .weight },
    \\            .arabic = .{ .color = .gradient1, .font = "Noto Sans Arabic" },
    \\            .thai = .{ .color = .text, .font = "Noto Sans Thai" },
    \\            .chinese = .{ .color = .text, .font = "Noto Sans CJK SC" },
    \\            .japanese = .{ .color = .text, .font = "Noto Sans CJK JP" },
    \\            .korean = .{ .color = .text, .font = "Noto Sans CJK KR" },
    \\        },
    \\    },
    \\}
;

fn findColor(t: OpenTables, name: []const u8) ?ColorEntry {
    for (t.colors) |c| if (std.mem.eql(u8, c.name, name)) return c.value;
    return null;
}
fn findGradient(t: OpenTables, name: []const u8) ?GradientLit {
    for (t.gradients) |g| if (std.mem.eql(u8, g.name, name)) return g.value;
    return null;
}
fn findStyle(t: OpenTables, name: []const u8) ?StyleSpec {
    for (t.styles) |s| if (std.mem.eql(u8, s.name, name)) return s.value;
    return null;
}

test "a whole file: every section is read, in any order" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var tables = try readOpenTables(gpa, user_file_src, &diag);
    defer freeOpenTables(gpa, &tables);

    try std.testing.expectEqual(@as(usize, 4), tables.colors.len);
    try std.testing.expectEqual(@as(usize, 2), tables.gradients.len);
    try std.testing.expectEqual(@as(usize, 2), tables.vars.len);
    try std.testing.expectEqual(@as(usize, 6), tables.styles.len);
}

test "a whole file: `.arrays are read, not dropped" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var tables = try readOpenTables(gpa, user_file_src, &diag);
    defer freeOpenTables(gpa, &tables);

    // A ZON array is written `.{\n`, never `{`. Missing the leading dot silently
    // dropped every array colour, which is the defect these three pin.
    try std.testing.expectEqual(ColorLit{ .rgb = .{ 128, 128, 128 } }, findColor(tables, "panel").?.solid);
    try std.testing.expectEqual(ColorLit{ .rgba = .{ 200, 200, 20, 167 } }, findColor(tables, "border").?.solid);
    try std.testing.expectEqual(@as(u32, 0x1e1e2e78), findColor(tables, "bg").?.solid.hex);
}

test "a whole file: floats scale by magnitude" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var tables = try readOpenTables(gpa, user_file_src, &diag);
    defer freeOpenTables(gpa, &tables);

    // All <= 1.0 is a fraction: 0.6*255 rounds to 153, 0.3*255 to 77.
    try std.testing.expectEqual(ColorLit{ .rgba = .{ 153, 128, 102, 77 } }, findColor(tables, "text").?.solid);
}

test "a whole file: two gradients survive" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var tables = try readOpenTables(gpa, user_file_src, &diag);
    defer freeOpenTables(gpa, &tables);

    // The gradient reader used to leave the wrapper's closing brace behind, so
    // the table stopped after the first entry.
    try std.testing.expect(findGradient(tables, "accent") != null);
    try std.testing.expect(findGradient(tables, "gradient1") != null);
    try std.testing.expectEqual(@as(f32, 135), findGradient(tables, "accent").?.linear.dir);
}

test "a whole file: a style resolves through .vars" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var tables = try readOpenTables(gpa, user_file_src, &diag);
    defer freeOpenTables(gpa, &tables);

    const latin = findStyle(tables, "latin").?;
    try std.testing.expectEqualStrings("accent", latin.color.?);
    // `.font = .latin_font` is a VAR, not a family: it must read as the family
    // the var holds, or the file would render the literal name.
    try std.testing.expectEqualStrings("Roboto Flex", latin.font.?);
    // `.weight = .weight` is the var, not the literal string.
    try std.testing.expectEqual(@as(u16, 600), latin.weight.?);

    const arabic = findStyle(tables, "arabic").?;
    try std.testing.expectEqualStrings("gradient1", arabic.color.?);
    try std.testing.expectEqualStrings("Noto Sans Arabic", arabic.font.?);
    try std.testing.expectEqual(@as(?u16, null), arabic.weight);
}

test "a missing var is an error, not a literal" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    const src =
        \\.{
        \\    .theme = .{
        \\        .styles = .{ .a = .{ .weight = .nope } },
        \\    },
        \\}
    ;
    const r = readOpenTables(gpa, src, &diag);
    try std.testing.expectError(error.Palette, r);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "nope") != null);
}

test "readColorLit: a truncated array is an error, not a short colour" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    // A two-number array has no reading: 3 is rgb, 4 is rgba. The fixture is
    // otherwise well-formed, because the point is the channel count, not a
    // truncated file -- an unbalanced file bails before reaching the entry and
    // would pass this test while proving nothing.
    const src =
        \\.{ .version = 3, .theme = .{ .colors = .{ .bg = .{ 10, 20 } } } }
    ;
    const r = readOpenTables(gpa, src, &diag);
    try std.testing.expectError(error.Palette, r);
}

test "readColorLit: a dot that is not an array is not a colour" {
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    // `.nope` is an identifier, not a colour. It must be refused by the reader
    // rather than handing back a half-consumed token.
    const src =
        \\.{ .version = 3, .theme = .{ .colors = .{ .bg = .nope } } }
    ;
    try std.testing.expectError(error.Palette, readOpenTables(gpa, src, &diag));
}

test "the shipped defaults carry no tagged colour form" {
    // The real check is behavioural, not textual: the file loads and every role
    // resolves. A file still in the old `.{ .hex = ... }` shape would fail to
    // parse, so this pins the format without grepping prose that explains it.
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(struct {}, std.testing.allocator, "theme.defaults.zon", defaults_zon, Theme{}, &diag);
    defer freeCustom(std.testing.allocator, &loaded.theme);
    defer freeStyles(std.testing.allocator, &loaded.styles);

    // `.bg` is the first role in the file; if the tagged form survived, this is
    // where a zero would show up.
    try std.testing.expectEqual(@as(u8, 0x1e), loaded.theme.bg.r);
    try std.testing.expectEqual(@as(u8, 0xff), loaded.theme.bg.a);
}

test "vars resolve from .theme.vars, not the root" {
    // The regression this pins: `.vars` lives INSIDE `.theme`. A probe at the
    // root found nothing, so `vars` was always the default while the file
    // reported as loaded -- every var-driven style silently resolved to null.
    const App = struct {
        weight: ?u16 = null,
        latin_font: ?[]const u8 = null,
    };
    const src =
        \\.{
        \\    .version = 3,
        \\    .theme = .{
        \\        .colors = .{ .bg = 0x1e1e2eaa },
        \\        .vars = .{ .weight = 600, .latin_font = "Roboto Flex" },
        \\        .styles = .{
        \\            .latin = .{ .font = .latin_font, .weight = .weight },
        \\        },
        \\    },
        \\}
    ;
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(App, gpa, "theme.zon", src, Theme{}, &diag);
    defer freeLoaded(App, gpa, &loaded);

    try std.testing.expectEqual(@as(?u16, 600), loaded.vars.weight);
    try std.testing.expectEqualStrings("Roboto Flex", loaded.vars.latin_font.?);

    // And the style sees the RESOLVED value, not the var name.
    try std.testing.expectEqual(@as(usize, 1), loaded.styles.len);
    try std.testing.expectEqualStrings("Roboto Flex", loaded.styles[0].spec.font.?);
    try std.testing.expectEqual(@as(?u16, 600), loaded.styles[0].spec.weight);
}

test "a style's .halo is read, not dropped" {
    // The regression this pins: `readStyleField` handled color/bg/border/font/
    // size/weight and fell through to `skipValue` for everything else, so a
    // `.halo` in a theme file produced NOTHING -- no error, no diagnostic, no
    // halo prim. The field existed downstream the whole time, which is why the
    // symptom was an element that simply had no glow rather than a rejection.
    const App = struct {};
    const src =
        \\.{
        \\    .version = 3,
        \\    .theme = .{
        \\        .colors = .{ .bg = 0x1e1e2e },
        \\        .styles = .{
        \\            .latin = .{ .halo = .{ .color = .bg, .blur = 8, .spread = 2, .offset = .{ 3, 4 } } },
        \\            .bare = .{},
        \\        },
        \\    },
        \\}
    ;
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(App, gpa, "theme.zon", src, Theme{}, &diag);
    defer freeLoaded(App, gpa, &loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.styles.len);
    const h = loaded.styles[0].spec.halo orelse return error.TestExpectedHalo;
    try std.testing.expectEqualStrings("bg", h.color);
    try std.testing.expectEqual(@as(f32, 8), h.blur);
    try std.testing.expectEqual(@as(f32, 2), h.spread);
    try std.testing.expectEqual(@as([2]f32, .{ 3, 4 }), h.offset);
    // A style that writes none stays null: a default halo would glow everything.
    try std.testing.expectEqual(@as(?HaloSpec, null), loaded.styles[1].spec.halo);
}

test "an unknown .halo key is an error, not a silent default" {
    // Inside a table the file itself opened, an unrecognised key is a typo.
    // `.blurr = 8` would otherwise leave the halo at the default blur and say
    // nothing -- the same silent-drop class as `.halo` being ignored outright.
    const App = struct {};
    const src =
        \\.{
        \\    .version = 3,
        \\    .theme = .{
        \\        .styles = .{ .a = .{ .halo = .{ .blurr = 8 } } },
        \\    },
        \\}
    ;
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    // The walker's own error now propagates, so a caller can tell a bad
    // palette from a malformed file without grepping the diagnostic.
    try std.testing.expectError(
        error.Palette,
        loadTheme(App, gpa, "theme.zon", src, Theme{}, &diag),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "blurr") != null);
}

test "a style's .frost and .stroke are read, not dropped" {
    // Both existed at the primitive level long before this: frost had a tested
    // SDF blur, stroke was one line in the rounded-rect fill. Neither was
    // reachable from a .zon, so writing either did nothing and said nothing --
    // the same silent-drop class as `.halo`.
    const App = struct {};
    const src =
        \\.{
        \\    .version = 3,
        \\    .theme = .{
        \\        .colors = .{ .bg = 0x1e1e2e },
        \\        .styles = .{
        \\            .glass = .{ .bg = .bg, .frost = .{ .blur = 9 }, .stroke = 3 },
        \\            .legacy = .{ .stroke = true },
        \\            .plain = .{},
        \\        },
        \\    },
        \\}
    ;
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    var loaded = try loadTheme(App, gpa, "theme.zon", src, Theme{}, &diag);
    defer freeLoaded(App, gpa, &loaded);

    try std.testing.expectEqual(@as(usize, 3), loaded.styles.len);
    const f = loaded.styles[0].spec.frost orelse return error.TestExpectedFrost;
    try std.testing.expectEqual(@as(f32, 9), f.blur);
    try std.testing.expectEqual(@as(?u8, 3), loaded.styles[0].spec.stroke);
    // `.stroke = true` is what the field used to be; it reads as 1px rather
    // than erroring, so an old theme keeps its outline instead of the fill it
    // was hiding.
    try std.testing.expectEqual(@as(?u8, 1), loaded.styles[1].spec.stroke);
    // A style that writes neither stays off: a default frost would blur
    // everything and a default stroke would empty every fill.
    try std.testing.expectEqual(@as(?FrostSpec, null), loaded.styles[2].spec.frost);
    try std.testing.expectEqual(@as(?u8, null), loaded.styles[2].spec.stroke);
}

test "an unknown .frost key is an error, not a silent default" {
    // `.blurrr` would otherwise leave the frost at the default radius and say
    // nothing, which is indistinguishable from the key having been ignored.
    const App = struct {};
    const src =
        \\.{
        \\    .version = 3,
        \\    .theme = .{
        \\        .styles = .{ .a = .{ .frost = .{ .blurrr = 8 } } },
        \\    },
        \\}
    ;
    const gpa = std.testing.allocator;
    var diag: ThemeDiag = .{};
    try std.testing.expectError(
        error.Palette,
        loadTheme(App, gpa, "theme.zon", src, Theme{}, &diag),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "blurrr") != null);
}
