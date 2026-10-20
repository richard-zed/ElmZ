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
// theme files: a flat .zon becomes a Theme
// ---------------------------------------------------------------------------

/// The shipped listing is the library default. It is embedded rather than
/// shipped beside the binary so a missing file cannot quietly become "no
/// theme": there is exactly one place defaults live, and it is compiled in
/// from the same file a user copies to start their own.
pub const defaults_zon: [:0]const u8 = @embedFile("theme.defaults.zon");

/// The version every loader understands. A file states it so a later schema
/// can refuse an old file in one sentence instead of a wall of type errors.
pub const theme_version: u32 = 1;

/// One theme section as written in a `.zon`: every field optional, `null`
/// meaning "inherit".
///
/// Fields are `u32` hex rather than `Color` because a `.zon` is literal data
/// -- no expressions, no calls -- so it cannot spell `Color.rgbHex(0x1e1e2e)`.
/// The hex-to-`Color` conversion happens once, in `overlay`.
pub const ThemeSpec = struct {
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
    pub fn overlay(self: ThemeSpec, base: Theme) Theme {
        var t = base;
        inline for (@typeInfo(ThemeSpec).@"struct".fields) |f| {
            if (@field(self, f.name)) |hex| @field(t, f.name) = Color.rgbHex(hex);
        }
        return t;
    }
};

/// The whole document: two sections, two structs, never merged.
///
/// Merging would need a collision rule, and every rule loses quietly: an app
/// token named `bg` would either shadow the library's role or silently revert
/// it to a default, and nothing would report either. Separate structs make the
/// collision impossible instead of merely decided.
pub fn ThemeFileType(comptime App: type) type {
    return struct {
        version: u32,
        theme: ThemeSpec = .{},
        app: App = .{},
    };
}

/// What a load produced: the resolved palette, plus whatever the app tier held.
pub fn Loaded(comptime App: type) type {
    return struct { theme: Theme, app: App };
}

/// One line, fixed capacity. The failure path is the last place that may
/// assume an allocator survived, and the band is one line wide anyway.
pub const ThemeDiag = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const ThemeDiag) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *ThemeDiag, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        self.len = written.len;
    }
};

/// `Palette` is separate from `Parse` because a file can be perfectly valid
/// ZON and still be an unusable theme: two interaction roles sharing a colour
/// is a defect in the values, not in the syntax, and the author needs to be
/// told which.
pub const ThemeLoadError = error{ Parse, Version, Palette, OutOfMemory };

/// First diagnostic, rendered as `name line:col: reason` -- the shape that
/// tells an author where to look. A band cannot show a stack of notes, so the
/// rest are dropped rather than wrapped.
fn diagFrom(diag: *ThemeDiag, name: []const u8, d: *std.zon.parse.Diagnostics, fallback: []const u8) void {
    var errors = d.iterateErrors();
    if (errors.next()) |err| {
        const loc = err.getLocation(d);
        diag.set("{s} {d}:{d}: {f}", .{ name, loc.line + 1, loc.column + 1, err.fmtMessage(d) });
        return;
    }
    diag.set("{s}: {s}", .{ name, fallback });
}

/// Parse `src` as a theme file over `base`.
///
/// `App` is the app tier's own flat struct, declared in Zig by the app. A key
/// the app did not declare is a parse error, which is what keeps a typo like
/// `accentt:` from silently doing nothing. `App` must be flat data (no
/// pointers) because `fromSlice` requires a type that needs no allocator.
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
    // to judge the rest of the keys against, and refusing them here would
    // report "this file is for a newer elmz" as an unknown-field error.
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

    return .{ .theme = theme, .app = file.app };
}

/// The library palette: the embedded listing laid over the compiled floor.
///
/// `Theme{}` stays a usable value at compile time (tests, defaults, `Ui`), so
/// its literals are a floor rather than the source. The file overlays all ten
/// roles, and a test asserts it does -- so the floor can never show through a
/// key someone forgot to list.
pub fn defaultTheme(gpa: Allocator, diag: *ThemeDiag) ThemeLoadError!Theme {
    const loaded = try loadTheme(struct {}, gpa, "theme.defaults.zon", defaults_zon, Theme{}, diag);
    return loaded.theme;
}

test "the palette guard is family-scoped" {
    // Mocha itself is clean, which is the case that must never regress.
    try checkPalette(.{});

    // An alias ACROSS families is legitimate and must PASS. This is exactly
    // what the old exact-equality guard rejected, which would have failed a
    // hand-written theme for spending fewer tokens.
    var alias = Theme{};
    alias.border = alias.text_muted;
    try checkPalette(alias);

    var alias2 = Theme{};
    alias2.border = alias2.accent;
    try checkPalette(alias2);

    // Inside the interaction family a collision is a real defect: `pressed`
    // landing on the same pixel as `hover` means the press has no visual
    // answer at all.
    var bad = Theme{};
    bad.pressed = bad.hover;
    try std.testing.expectError(error.DuplicateRole, checkPalette(bad));

    // Same for text: when primary and secondary coincide, nothing is muted.
    var flat = Theme{};
    flat.text_muted = flat.text;
    try std.testing.expectError(error.DuplicateRole, checkPalette(flat));

    // The two large fills may not coincide: a panel in the page colour is
    // invisible, which is the failure this family exists for.
    var flat_page = Theme{};
    flat_page.panel = flat_page.bg;
    try std.testing.expectError(error.DuplicateRole, checkPalette(flat_page));

    // Every token must be filed, so adding a role to `Theme` cannot slip past
    // the guard by being unclassified.
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        try std.testing.expect(familyOf(f.name) != null);
    }
}

test "the shipped defaults list every role" {
    var d: std.zon.parse.Diagnostics = .{};
    defer d.deinit(std.testing.allocator);
    const file = try std.zon.parse.fromSlice(ThemeFileType(struct {}), std.testing.allocator, defaults_zon, &d, .{});

    // A role added to `Theme` and forgotten in the file would leave the
    // compiled literal showing through, which is the one way the file stops
    // being the source of default values.
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        try std.testing.expect(@hasField(ThemeSpec, f.name));
        try std.testing.expect(@field(file.theme, f.name) != null);
    }
}

test "the shipped defaults resolve to the compiled palette" {
    var diag: ThemeDiag = .{};
    const t = try defaultTheme(std.testing.allocator, &diag);
    try std.testing.expect(std.meta.eql(@as(Theme, .{}), t));
}

test "an override replaces exactly one role" {
    const src = ".{ .version = 1, .theme = .{ .accent = 0xff0000 } }";
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(Color.rgbHex(0xff0000), loaded.theme.accent));
    try std.testing.expect(std.meta.eql((Theme{}).bg, loaded.theme.bg));
}

test "a file whose interaction roles collide is rejected" {
    // Syntactically fine, unusable as a theme: `hover` identical to `control`
    // means a hovered control looks exactly like a resting one. The palette
    // guard has to run on loaded files, or it only ever protects the defaults.
    const src = ".{ .version = 1, .theme = .{ .hover = 0x45475a } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(
        error.Palette,
        loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "DuplicateRole") != null);
}

test "a bad value names the file, line and column" {
    const src = ".{ .version = 1, .theme = .{ .bg = \"blue\" } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    try std.testing.expect(std.mem.startsWith(u8, diag.text(), "theme.zon 1:"));
    // The reason has to name what was expected, not just that something failed:
    // "expected type '?u32'" tells the author which key is wrong.
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "expected type") != null);
}

test "an unknown key in the theme section is rejected" {
    // This is the typo case: `bgx` must not be silently ignored, or `accentt:`
    // would fail to apply and nothing would say so.
    const src = ".{ .version = 1, .theme = .{ .bgx = 0xff0000 } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    // The rejected key must be named, or a typo reads as an unrelated error.
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "bgx") != null);
}

test "an unknown top-level section is rejected" {
    const src = ".{ .version = 1, .themes = .{} }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Parse, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
}

test "a different version is refused in one sentence" {
    const src = ".{ .version = 2, .theme = .{ .bg = 0x000000 } }";
    var diag: ThemeDiag = .{};
    try std.testing.expectError(error.Version, loadTheme(struct {}, std.testing.allocator, "theme.zon", src, Theme{}, &diag));
    try std.testing.expectEqualStrings("theme.zon: version 2 is not 1", diag.text());
}

test "the version probe tolerates sections it does not know" {
    // `.app` is outside the probe's schema. A strict probe would reject this
    // file as unknown-field instead of reading its version and moving on.
    const src = ".{ .version = 1, .theme = .{}, .app = .{ .outer_box_border = 4 } }";
    const App = struct { outer_box_border: u8 = 0 };
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(App, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expectEqual(4, loaded.app.outer_box_border);
}

test "an app token cannot shadow a library role" {
    // Two structs, never merged: `bg` in the app tier is a different key from
    // the theme's `bg`, and the library value is untouched.
    const src = ".{ .version = 1, .theme = .{ .bg = 0x112233 }, .app = .{ .bg = 0x445566 } }";
    const App = struct { bg: ?u32 = null };
    var diag: ThemeDiag = .{};
    const loaded = try loadTheme(App, std.testing.allocator, "theme.zon", src, Theme{}, &diag);
    try std.testing.expect(std.meta.eql(Color.rgbHex(0x112233), loaded.theme.bg));
    try std.testing.expectEqual(@as(?u32, 0x445566), loaded.app.bg);
}

test "the palette guard names the offending pair" {
    // The message used to come out of a print inside the guard. It is a return
    // value now, so a failure says WHICH two roles collided without any test
    // writing to stderr.
    var bad = Theme{};
    bad.hover = bad.control;
    try std.testing.expectEqual(error.DuplicateRole, checkPalette(bad) catch |e| e);

    const c = firstCollision(bad).?;
    try std.testing.expectEqual(RoleFamily.interaction, c.family);
    try std.testing.expectEqualStrings("control", c.a);
    try std.testing.expectEqualStrings("hover", c.b);

    try std.testing.expect(firstCollision(.{}) == null);
}
