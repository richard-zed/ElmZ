//! Themes: the palette roles, the guard that keeps them readable, and the
//! `.zon` loader.
//!
//! Split out of `elmz.zig` because none of it is about layout, painting or
//! events. `Theme` stays there -- it is a value every part of the library
//! reads -- so the dependency runs one way: this file imports `elmz.zig`.
//!
//! An app copies `theme.defaults.zon`, edits it, sets `theme_path`, and the
//! runner reloads it while the window is open.

const std = @import("std");
const elmz = @import("elmz.zig");
const Theme = elmz.Theme;
const Color = elmz.Color;
const Allocator = std.mem.Allocator;

/// Roles are grouped by what a collision costs, because a duplicate between
/// two roles is only a bug when the two have to be told apart.
///
/// The old guard demanded that no two roles shared a colour, which is true
/// only of a sharp palette like Mocha's. A hand-written theme that reuses one
/// grey for `border` and `text_muted` is not wrong -- it is a theme author spending
/// fewer tokens -- and the guard has no business rejecting it.
pub const RoleFamily = enum {
    /// Fill states that must be distinguishable from each other while a
    /// control changes state. `selected` lighter than `control` is what makes
    /// an active tab read as active rather than disabled, so a collision here
    /// is the one that actually breaks a UI.
    interaction,
    /// Text on a panel: primary and secondary must differ or nothing reads
    /// as de-emphasised.
    text,
    /// The two large adjacent fills. A panel in the page colour is a panel
    /// nobody can see, so these may not coincide -- but each may reuse a
    /// colour from any other family.
    fill,
    /// Lines. A single role, so it can alias freely: a border in the caption
    /// colour is a theme author spending fewer tokens, not a defect.
    line,
    /// Emphasis, checked only against itself.
    emphasis,
};

/// Every field must appear exactly once: an unfiled token is
/// `error.UnfiledRole`, so a role added to `Theme` cannot be outgrown by the
/// guard silently.
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

/// The first pair of same-family roles sharing a colour, or null when the
/// palette is legal.
///
/// Returned rather than printed. A test that writes to stderr makes the build
/// runner record the step as failed -- `zig build test` then prints
/// `failed command: ... --listen=-` on an otherwise green run. The pair a test
/// can assert on is worth more than a line of output anyway.
pub fn firstCollision(t: Theme) ?Collision {
    const fields = @typeInfo(Theme).@"struct".fields;
    inline for (fields, 0..) |f, i| {
        // `if`-capture, not `orelse continue`: `continue` inside an inline for
        // is comptime control flow in a runtime block, which does not compile.
        if (familyOf(f.name)) |fi| {
            inline for (fields[i + 1 ..]) |g| {
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
        if (familyOf(f.name) == null) return error.UnfiledRole;
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
//   .colors    = .{ .bg = 0x1e1e2e }             -- terse, the common case,
//                                                   what a person edits by hand
//   .gradients = .{ .bg = .{ .linear = ... } }   -- explicit, because a
//                                                   gradient is not a number
//
// Keeping `.colors` as hex is not laziness: ZON will not coerce a bare integer
// into a union payload (verified by compiling), so a single unified field would
// force `.{ .solid = 0x1e1e2e }` on all ten roles, in every file, forever.

/// The shipped listing is the library default. Embedded rather than shipped
/// beside the binary so a missing file cannot quietly become "no theme".
pub const defaults_zon: [:0]const u8 = @embedFile("theme.defaults.zon");

/// Every loader version this file understands. A file states its own so a v1
/// file is refused in one sentence instead of half-loading and looking wrong.
pub const theme_version: u32 = 2;

/// Gradient direction for the linear case: degrees on a clock face, clockwise
/// from 12 o'clock, naming the direction the ramp TRAVELS.
///
///   0   ->  bottom to top
///   45  ->  up and to the right
///   90  ->  left to right
///   135 ->  down and to the right
///   180 ->  top to bottom  (the default, and what `vertical` used to mean)
///   270 ->  right to left
///
/// A float rather than a three-value enum because such an enum could only ever
/// express three directions -- every other angle was unreachable, and the way
/// out would have been to fake it with a radial. The renderer was never the
/// limit: `Fill.Linear` is two vectors, so any angle it is given is exact.
///
/// Mind the sense: this names where the colour is GOING. `Halo.light` uses the
/// same clock but names where the lamp SITS, so at the same number the two
/// point opposite ways.
pub const LinearSpec = struct {
    dir: f32 = 180,
    /// `null` inherits the role's own colour from `.colors`. Leaving an end
    /// out is how a gradient stays tied to the palette instead of holding a
    /// second copy of the same hex.
    from: ?u32 = null,
    to: ?u32 = null,
};

pub const RadialSpec = struct {
    /// The colour at the centre and the colour it falls off to. `null`
    /// inherits the role's own colour, same as the linear ends.
    inner: ?u32 = null,
    outer: ?u32 = null,
    /// Where the centre sits, as a fraction of the element's box. `.{0, 0}` is
    /// the top-left corner, `.{0.5, 0.5}` the middle. Fractions rather than
    /// pixels because an element does not know where layout will put it, so a
    /// pixel offset would slide as soon as anything above it grew.
    center: ?[2]f32 = null,
    /// Fraction of the box WIDTH, matching `Fill.Radial`.
    radius: f32 = 0.5,
};

/// A gradient as written in a file.
///
/// There is deliberately no `solid` variant: a flat colour belongs in
/// `.colors`, and giving it a second spelling here would create a file where
/// one role is stated twice with no rule about which wins.
pub const GradientSpec = union(enum) {
    linear: LinearSpec,
    radial: RadialSpec,

    /// `fallback` is the role's resolved colour, used for whichever end the
    /// file left out.
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
///
/// Fields are `u32` hex rather than `Color` because a `.zon` is literal data --
/// no expressions, no calls -- so it cannot spell `Color.rgbHex(0x1e1e2e)`.
pub const ColorsSpec = struct {
    bg: ?u32 = null,
    panel: ?u32 = null,
    border: ?u32 = null,
    text: ?u32 = null,
    text_muted: ?u32 = null,
    control: ?u32 = null,
    hover: ?u32 = null,
    pressed: ?u32 = null,
    selected: ?u32 = null,
    accent: ?u32 = null,

    /// `base` supplies whatever the spec leaves null. The field names mirror
    /// `Theme`; a test proves they stay mirrored, and this inline loop is what
    /// makes adding a role a one-line change on this side.
    pub fn overlay(self: ColorsSpec, base: Theme) Theme {
        var t = base;
        inline for (@typeInfo(ColorsSpec).@"struct".fields) |f| {
            if (@field(self, f.name)) |hex| @field(t, f.name) = Color.rgbHex(hex);
        }
        return t;
    }
};

/// Gradients per role, named exactly like the colours they stand in for.
///
/// Same names on purpose: "a gradient for `accent`" has one obvious spelling,
/// and a free catalogue of arbitrary names would need a lookup table and would
/// let a gradient exist that no role ever reaches.
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
};

/// The resolved gradients: a role with no gradient is null, which is how every
/// consumer spells "use the solid colour".
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

    pub fn any(self: Gradients) bool {
        inline for (@typeInfo(Gradients).@"struct".fields) |f| {
            if (@field(self, f.name) != null) return true;
        }
        return false;
    }

    /// The gradient for a role by name, or null. Lets an app say
    /// `ui.gradients.get("accent")` without knowing the whole shape.
    pub fn get(self: Gradients, name: []const u8) ?elmz.Fill {
        inline for (@typeInfo(Gradients).@"struct".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @field(self, f.name);
        }
        return null;
    }
};

/// One theme section as written: two nested tables, both optional.
pub const ThemeSpec = struct {
    colors: ColorsSpec = .{},
    gradients: GradientsSpec = .{},

    /// Solid colours over `base`. Gradients resolve separately because they are
    /// a different type and a different question.
    pub fn overlay(self: ThemeSpec, base: Theme) Theme {
        return self.colors.overlay(base);
    }

    /// `theme` is the already-resolved palette, which is where an omitted
    /// gradient end gets its colour. Passing it here rather than at paint time
    /// means a gradient and the palette can never disagree.
    pub fn resolveGradients(self: ThemeSpec, theme: Theme) Gradients {
        var out: Gradients = .{};
        inline for (@typeInfo(GradientsSpec).@"struct".fields) |f| {
            if (@field(self.gradients, f.name)) |spec| {
                @field(out, f.name) = spec.resolve(@field(theme, f.name));
            }
        }
        return out;
    }
};

/// The whole document. `.app` is typed by whoever claims it.
///
/// There is no lenient mode. An app that wants tokens in the theme file
/// declares a struct and gets them, checked; an app that declares nothing has
/// no app tier, and a file that writes one is told so. Waving unknown keys
/// through would need `ignore_unknown_fields`, which is FILE-WIDE (verified by
/// compiling: a typo inside `.colors` is silently accepted once it is on), so
/// the tier would be paid for with the typo detection that makes the error band
/// worth having.
pub fn ThemeFileType(comptime App: type) type {
    return struct {
        version: u32,
        theme: ThemeSpec = .{},
        app: App = .{},
    };
}

/// What a load produced: the palette, its gradients, and the app tier.
pub fn Loaded(comptime App: type) type {
    return struct { theme: Theme, gradients: Gradients = .{}, app: App = .{} };
}

/// One line, fixed capacity. The failure path is the last place that may
/// assume an allocator survived, and the band is one line wide anyway.
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

/// `Palette` is separate from `Parse` because a file can be perfectly valid
/// ZON and still be an unusable theme: two interaction roles sharing a colour
/// is a defect in the values, not in the syntax, and the author needs to be
/// told which.
pub const ThemeLoadError = error{ Parse, Version, Palette, OutOfMemory };

/// First diagnostic, rendered as `name line:col: reason` -- the shape that
/// tells an author where to look.
fn diagFrom(diag: *ThemeDiag, name: []const u8, d: *std.zon.parse.Diagnostics, fallback: []const u8) void {
    var errors = d.iterateErrors();
    if (errors.next()) |err| {
        const loc = err.getLocation(d);
        diag.set("{s} {d}:{d}: {f}", .{ name, loc.line + 1, loc.column + 1, err.fmtMessage(d) });
        return;
    }
    diag.set("{s}: {s}", .{ name, fallback });
}

/// Parse `src` as a v2 theme file over `base`.
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

    var d: std.zon.parse.Diagnostics = .{};
    defer d.deinit(gpa);
    const file = std.zon.parse.fromSlice(ThemeFileType(App), gpa, src, &d, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            diagFrom(diag, name, &d, "bad theme file");
            return error.Parse;
        },
    };

    const theme = file.theme.overlay(base);

    // The shipped file is checked by the suite; a user's file is not, and it is
    // the one that can go wrong. A guard that only ever runs in tests protects
    // nothing the user will hit.
    checkPalette(theme) catch |e| {
        diag.set("{s}: {t}", .{ name, e });
        return error.Palette;
    };

    return .{ .theme = theme, .gradients = file.theme.resolveGradients(theme), .app = file.app };
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
        try std.testing.expect(familyOf(f.name) != null);
    }
}

test "the shipped defaults list every role" {
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.defaults.zon", defaults_zon, Theme{}, &diag);

    // A role added to `Theme` and forgotten in the file would leave the
    // compiled literal showing through, which is the one way the file stops
    // being the source of default values.
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        try std.testing.expect(@hasField(ColorsSpec, f.name));
        try std.testing.expect(@hasField(GradientsSpec, f.name));
    }

    // The file ships no gradients: a default gradient would be a look, and the
    // library's default look is a flat palette.
    try std.testing.expect(!loaded.gradients.any());
}

test "the shipped defaults resolve to the compiled palette" {
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.defaults.zon", defaults_zon, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(@as(Theme, .{}), loaded.theme));
}

test "an override replaces exactly one role" {
    const src = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0xff0000 } } }";
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(Color.rgbHex(0xff0000), loaded.theme.accent));
    try std.testing.expect(std.meta.eql((Theme{}).bg, loaded.theme.bg));
}

test "a gradient resolves to the fill a theme could never express before" {
    const src =
        \\.{ .version = 2, .theme = .{ .gradients = .{
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
        \\.{ .version = 2, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = 90, .from = 0xff0000, .to = 0x0000ff } } } } }
    )).linear;
    try std.testing.expectApproxEqAbs(@as(f32, 0), h.from[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.to[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), h.from[1], 1e-6);

    // 180 runs top to bottom -- clock 6, what the old `vertical` default meant.
    const v = (try case.load(
        \\.{ .version = 2, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = 180, .from = 0xff0000, .to = 0x0000ff } } } } }
    )).linear;
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.from[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), v.to[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), v.from[0], 1e-6);

    // An angle the enum could not name still spans the whole box: the delta is
    // a unit vector, so turning the ramp never shrinks it.
    const a = (try case.load(
        \\.{ .version = 2, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = 22, .from = 0xff0000, .to = 0x0000ff } } } } }
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
        \\.{ .version = 2, .theme = .{ .gradients = .{
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
        \\.{ .version = 2, .theme = .{ .gradients = .{ .panel = .{ .radial = .{} } } } }
    , Theme{}, &diag2);
    try std.testing.expectEqual(@as(f32, 0.5), mid.gradients.panel.?.radial.center[0]);
}

test "an omitted gradient end inherits the role colour" {
    // The drift this removes: a gradient that spells both ends holds a second
    // copy of the palette, so editing `.colors` leaves it behind. Naming only
    // the end that differs keeps it tied to the palette.
    const only_to =
        \\.{ .version = 2, .theme = .{
        \\    .colors = .{ .accent = 0x112233 },
        \\    .gradients = .{ .accent = .{ .linear = .{ .dir = 0, .to = 0xffffff } } },
        \\} }
    ;
    var diag: ThemeDiag = .{};
    const a = try loadTheme(struct {}, std.testing.allocator, "theme.zon", only_to, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(
        a.gradients.accent.?,
        elmz.Fill.angled(0, Color.rgbHex(0x112233), Color.rgbHex(0xffffff)),
    ));

    // Same gradient, different palette role: the inherited end moves with it.
    const other =
        \\.{ .version = 2, .theme = .{
        \\    .colors = .{ .accent = 0x445566 },
        \\    .gradients = .{ .accent = .{ .linear = .{ .dir = 0, .to = 0xffffff } } },
        \\} }
    ;
    var diag2: ThemeDiag = .{};
    const b = try loadTheme(struct {}, std.testing.allocator, "theme.zon", other, Theme{}, &diag2);
    try std.testing.expect(std.meta.eql(
        b.gradients.accent.?,
        elmz.Fill.angled(0, Color.rgbHex(0x445566), Color.rgbHex(0xffffff)),
    ));

    // A radial with nothing named is the role colour at both ends: legal, and
    // visibly a no-op rather than an error.
    const bare =
        \\.{ .version = 2, .theme = .{
        \\    .gradients = .{ .panel = .{ .radial = .{ .radius = 0.4 } } },
        \\} }
    ;
    var diag3: ThemeDiag = .{};
    const c = try loadTheme(struct {}, std.testing.allocator, "theme.zon", bare, Theme{}, &diag3);
    // The radius came from the file, so the expectation has to carry it too --
    // comparing against the default 0.5 is the mistake this assertion made
    // first, and it failed for that reason rather than because inheritance broke.
    var expected = elmz.Fill.radialFill((Theme{}).panel, (Theme{}).panel);
    expected.radial.radius = 0.4;
    try std.testing.expect(std.meta.eql(c.gradients.panel.?, expected));
}

test "a gradient direction typo is a parse error, not a fallback" {
    const src = ".{ .version = 2, .theme = .{ .gradients = .{ .bg = .{ .linear = .{ .dir = .sideways, .from = 0, .to = 1 } } } } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
}

test "a theme file cannot compute anything" {
    // The values-only property, stated where a regression would be caught: a
    // theme file that tried to call or import would be rejected by the parser
    // before any of our code runs.
    const cases = [_][:0]const u8{
        ".{ .version = 2, .theme = .{ .colors = .{ .bg = 1 + 1 } } }",
        ".{ .version = 2, .theme = .{ .colors = .{ .bg = @import(\"std\") } } }",
        ".{ .version = 2, .theme = .{ .colors = .{ .bg = compute() } } }",
    };
    for (cases) |src| {
        var diag: ThemeDiag = .{};
        try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    }
}

test "a file whose interaction roles collide is rejected" {
    const src = ".{ .version = 2, .theme = .{ .colors = .{ .hover = 0x45475a } } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(
        error.Palette,
        loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "DuplicateRole") != null);
}

test "a bad value names the file, line and column" {
    const src = ".{ .version = 2, .theme = .{ .colors = .{ .bg = \"blue\" } } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    try std.testing.expect(std.mem.startsWith(u8, diag.text(), "theme.zon 1:"));
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "expected type") != null);
}

test "an unknown key in the theme section is rejected" {
    const src = ".{ .version = 2, .theme = .{ .colors = .{ .bgx = 0xff0000 } } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "bgx") != null);
}

test "an unknown key in the gradients section is rejected" {
    // `.gradients` is a typed table, not a free catalogue: a misspelled role
    // would otherwise sit in the file looking like it did something.
    const src = ".{ .version = 2, .theme = .{ .gradients = .{ .accentt = .{ .linear = .{ .from = 0, .to = 1 } } } } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "accentt") != null);
}

test "the v1 shape is refused rather than half-read" {
    // v1 was flat: `.theme = .{ .bg = ... }`. Loaded as v2 it would parse and
    // produce a palette where every role silently reverted to the default,
    // which looks like "my theme did nothing" rather than "my theme is old".
    const v1 = ".{ .version = 1, .theme = .{ .bg = 0x112233 } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Version, loadTheme(struct {}, std.testing.allocator, "theme.zon", v1, Theme{}, &diag));
    try std.testing.expectEqualStrings("theme.zon: version 1 is not 2", diag.text());

    // A v2 file that keeps the v1 nesting is a parse error naming the key it
    // does not recognise, not a silent no-op.
    const misnested = ".{ .version = 2, .theme = .{ .bg = 0x112233 } }";
    var diag2: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", misnested, Theme{}, &diag2));
    try std.testing.expect(std.mem.indexOf(u8, diag2.text(), "bg") != null);
}

test "an unknown top-level section is rejected" {
    const src = ".{ .version = 2, .themes = .{} }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
}

test "an app tier nobody declared is refused, and named" {
    // No lenient mode: the tier is for app writers, so an app that wants it
    // declares a struct. Waving unknown keys through would cost the theme its
    // typo detection, because `ignore_unknown_fields` is file-wide.
    const src = ".{ .version = 2, .theme = .{}, .app = .{ .outer_box_border = 4 } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    // The offending KEY is named, not just the section: "unexpected field
    // 'outer_box_border'" tells the writer to declare it, which is the whole
    // remedy.
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "outer_box_border") != null);
}

test "an app that declares its tokens gets them, strictly" {
    const App = struct { outer_box_border: u8 = 0, hero: ?u32 = null };
    const src = ".{ .version = 2, .theme = .{}, .app = .{ .outer_box_border = 4, .hero = 0xccddff } }";
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(App, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expectEqual(4, loaded.app.outer_box_border);
    try std.testing.expectEqual(@as(?u32, 0xccddff), loaded.app.hero);

    // Claiming it means it is checked: a typo in the app tier is an error.
    const typo = ".{ .version = 2, .theme = .{}, .app = .{ .outer_box_bordr = 4 } }";
    try std.testing.expectError(error.Parse, loadTheme(App, std.testing.allocator, "theme.zon", typo, Theme{}, &diag));
}

test "an app token cannot shadow a library role" {
    const src = ".{ .version = 2, .theme = .{ .colors = .{ .bg = 0x112233 } }, .app = .{ .bg = 0x445566 } }";
    const App = struct { bg: ?u32 = null };
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(App, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(Color.rgbHex(0x112233), loaded.theme.bg));
    try std.testing.expectEqual(@as(?u32, 0x445566), loaded.app.bg);
}

test "the app tier is optional" {
    const App = struct { hero: ?u32 = null };
    const src = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0x112233 } } }";
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(App, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(Color.rgbHex(0x112233), loaded.theme.accent));
    try std.testing.expectEqual(@as(?u32, null), loaded.app.hero);
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
