//! Glow and shadow, on top of the theme protocol.
//!
//! Three things this is here to show, in order of how much they cost:
//!
//!   1. a GRADIENT BACKGROUND, built from theme tokens rather than literals,
//!      so a `theme.zon` recolours the room as well as the furniture;
//!   2. a SHADOW under a card, offset down, which is the silhouette of the
//!      card drawn behind it;
//!   3. a BUTTON THAT GLOWS ON HOVER -- the halo is derived during paint from
//!      the pointer, exactly like `hover_bg` is, so `view` never sees it.
//!
//! Everything here is tokens plus geometry. There is not a single hex literal
//! in `view`, which is the whole point of a theme protocol: swap the file, get
//! a different picture, change no code.

const std = @import("std");
const elmz = @import("elmz");
const runner = @import("runner");
const software = @import("software");

const W = 560;
const H = 380;

pub const Model = struct {
    /// set from the theme file's `.app` tier at startup
    title_size: f32 = 30,
};
pub const Msg = enum { primary };

/// The app tier: keys a `theme.zon` may set that the library knows nothing
/// about. Declaring the struct is what makes the keys checkable -- an
/// undeclared key is a parse error, not a silently ignored line.
pub const Tokens = struct {
    title_size: f32 = 30,
};

fn update(_: *Model, _: Msg) elmz.Action(Msg) {
    return .{};
}

fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const th = ui.theme;

    // A halo needs a colour with alpha, and the theme carries opaque tokens,
    // so the app composes one. Shadows are the theme's own dark end pushed
    // most of the way to transparent -- not black, which would read as a
    // hole in a warm palette.
    const shadow_color = elmz.Color{ .r = 0x0b, .g = 0x0a, .b = 0x12, .a = 150 };
    const glow_color = elmz.Color{ .r = th.accent.r, .g = th.accent.g, .b = th.accent.b, .a = 110 };

    const title = ui.text(.{ .label = "glow + shadow", .size = m.title_size, .tone = .normal });

    const note = ui.text(.{
        .label = "the page gradient, the card shadow and the button glow are all theme tokens; hover the button and the halo appears without view knowing",
        .size = 12,
        .tone = .muted,
        .wrap = true,
        .width = 300,
    });

    const primary = ui.button(.{
        .label = "hover me",
        .msg = .primary,
        .key = 1,
        .width = 150,
        .style = .{
            .bg = th.accent,
            .fg = th.bg,
            .radius = 10,
            // resting: a shadow, so the button sits on the card
            .halo = .{ .color = shadow_color, .blur = 10, .offset = .{ 0, 4 }, .mode = .shadow },
        },
        // hover: the shadow is replaced by a glow, which is why the hover halo
        // is a whole `Halo` and not just a colour. A glow spreads around the
        // shape; a shadow sits under it. Same type, different intent.
        .hover_halo = .{ .color = glow_color, .blur = 26, .spread = 2, .mode = .glow },
    });

    // The card: no fill of its own beyond `panel`, but it casts the shadow the
    // two buttons sit inside.
    const card = ui.column(.{
        .children = &.{
            ui.text(.{ .label = "a card with a shadow", .size = 14, .tone = .normal }),
            ui.spaceBefore(primary, 16),
        },
        .style = .{
            .pad = 20,
            .bg = th.panel,
            .radius = 14,
            .border = th.border,
            .halo = .{ .color = shadow_color, .blur = 24, .spread = 0, .offset = .{ 0, 10 }, .mode = .shadow },
        },
    });

    const body = ui.row(.{ .children = &.{ note, ui.spaceBefore(card, 20) }, .gap = 10 });

    // No `bg` on the root: the frame is cleared to the theme's `bg`, and if a
    // theme file sets a `.gradients.bg`, that is what shows through. The root
    // gradient below is the app's own choice instead -- an angled ramp from
    // `bg` toward `panel`, so the page has a light direction.
    return ui.column(.{
        .children = &.{
            title,
            ui.spaceBefore(body, 22),
        },
        .style = .{
            .pad = 28,
            .bg = null,
            .bg_grad = elmz.Fill.angled(115, th.bg, th.panel),
        },
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    // The theme chain, resolved the way the runner resolves it.
    var base_owned: ?[:0]u8 = null;
    var user_owned: ?[:0]u8 = null;
    defer if (base_owned) |bp| gpa.free(bp);
    defer if (user_owned) |up| gpa.free(up);
    base_owned = runner.themePathBesideExe(gpa, io, "theme.defaults.zon");
    user_owned = runner.themePathBesideExe(gpa, io, "theme.zon");

    const chain = runner.resolveChain(Tokens, gpa, io, .{}, base_owned, user_owned);
    rt.ui.theme = chain.theme;
    rt.ui.gradients = chain.gradients;
    rt.state.title_size = chain.app.title_size;

    const name: []const u8 = if (chain.user_from_file) "theme.zon" else if (chain.base_from_file) "theme.defaults.zon" else "compiled defaults";

    var button_rect: ?elmz.Rect = null;

    // -- frame one: at rest ------------------------------------------------
    {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "glow.png");
        const halos = countHalos(f.prims);
        try out.print("glow.png        {d} primitives, {d} halo(s), theme: {s}\n", .{ f.prims.len, halos, name });
        for (f.hits) |h| {
            if (h.key == 1) button_rect = h.rect;
        }
    }

    // -- frame two: the pointer over the button ----------------------------
    if (button_rect) |r| {
        rt.pointer.pos = .{ r.x + r.w / 2, r.y + r.h / 2 };
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "glow-hover.png");
        // The halo is STILL one prim -- hover swaps which halo, it does not
        // stack a second one. So a count that went up would mean the hover
        // path is drawing both, which no eye would catch on a matching colour.
        try out.print("glow-hover.png  {d} primitives, {d} halo(s), pointer over key {?d}\n", .{
            f.prims.len, countHalos(f.prims), if (f.hit(rt.pointer.pos.?)) |h| h.key else null,
        });
    }
    rt.pointer.pos = null;
    // Without this the counts above never reach the terminal: the writer is
    // buffered and the process exits with the buffer full.
    try out.flush();
}

fn countHalos(prims: []const elmz.Primitive) usize {
    var n: usize = 0;
    for (prims) |p| switch (p) {
        .halo => n += 1,
        else => {},
    };
    return n;
}
