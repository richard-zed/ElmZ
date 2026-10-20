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

/// Gradient direction for the linear case. Names are ZON enum literals, so a
/// typo is a parse error naming the key rather than a silent fallback.
pub const Dir = enum { vertical, horizontal, diagonal };

pub const LinearSpec = struct {
    dir: Dir = .vertical,
    from: u32,
    to: u32,
};

pub const RadialSpec = struct {
    /// The colour at the centre and the colour it falls off to.
    inner: u32,
    outer: u32,
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

    pub fn resolve(self: GradientSpec) elmz.Fill {
        return switch (self) {
            .linear => |l| switch (l.dir) {
                .vertical => elmz.Fill.vgrad(Color.rgbHex(l.from), Color.rgbHex(l.to)),
                .horizontal => elmz.Fill.hgrad(Color.rgbHex(l.from), Color.rgbHex(l.to)),
                .diagonal => elmz.Fill.diag(Color.rgbHex(l.from), Color.rgbHex(l.to)),
            },
            .radial => |r| blk: {
                var f = elmz.Fill.radialFill(Color.rgbHex(r.inner), Color.rgbHex(r.outer));
                f.radial.radius = r.radius;
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

    pub fn resolveGradients(self: ThemeSpec) Gradients {
        var out: Gradients = .{};
        inline for (@typeInfo(GradientsSpec).@"struct".fields) |f| {
            if (@field(self.gradients, f.name)) |spec| @field(out, f.name) = spec.resolve();
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

    return .{ .theme = theme, .gradients = file.theme.resolveGradients(), .app = file.app };
}

/// The library palette: the embedded listing laid over the compiled floor.
pub fn defaultTheme(gpa: Allocator, diag: *ThemeDiag) ThemeLoadError!Theme {
    const loaded = try loadTheme(struct {}, gpa, "theme.defaults.zon", defaults_zon, Theme{}, diag);
    return loaded.theme;
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
    const t = try defaultTheme(std.testing.allocator, &diag);
    try std.testing.expect(std.meta.eql(@as(Theme, .{}), t));
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
        \\    .accent = .{ .linear = .{ .dir = .diagonal, .from = 0x89b4fa, .to = 0xf5c2e7 } },
        \\    .panel = .{ .radial = .{ .inner = 0x313244, .outer = 0x1e1e2e, .radius = 0.75 } },
        \\} } }
    ;
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);

    const accent = loaded.gradients.accent.?;
    try std.testing.expectEqual(elmz.Fill.linear, std.meta.activeTag(accent));
    // Diagonal, so the gradient vector runs corner to corner rather than down.
    try std.testing.expectApproxEqAbs(@as(f32, 1), accent.linear.to[1], 0.0001);

    const panel = loaded.gradients.panel.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), panel.radial.radius, 0.0001);

    // The colour roles are untouched: a gradient for `accent` does not silently
    // restate `accent`, so the solid palette and its guard stay meaningful.
    try std.testing.expect(std.meta.eql((Theme{}).accent, loaded.theme.accent));

    // And lookup by role name works, so an app need not know the shape.
    try std.testing.expect(loaded.gradients.get("accent") != null);
    try std.testing.expect(loaded.gradients.get("nothing") == null);
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
