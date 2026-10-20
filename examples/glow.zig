//! Glow and shadow, on top of the theme protocol.
//!
//! Three things this is here to show, in order of how much they cost:
//!
//!   1. a GRADIENT BACKGROUND, built from theme tokens rather than literals,
//!      so a `theme.zon` recolours the room as well as the furniture;
//!   2. a SHADOW under a card, offset down, which is the silhouette of the
//!      card drawn behind it;
//!   3. a BUTTON THAT GLOWS ON HOVER -- the halo is derived during paint from
//!      the pointer, exactly like `hover_bg` is, so `view` never sees it;
//!   4. TWO BUTTONS THAT ARE THE SAME BUTTON, one asking the distance field
//!      for its halo and one asking for a baked stencil. Same blur, same
//!      spread, same colour: if the two renderers ever disagree, a person sees
//!      both in one glance instead of having to remember the last one. The
//!      pixel-level agreement claim lives in the test suite, not in the eye.
//!
//! Everything here is tokens plus geometry. There is not a single hex literal
//! in `view`, which is the whole point of a theme protocol: swap the file, get
//! a different picture, change no code.

const std = @import("std");
const elmz = @import("elmz");
const runner = @import("runner");
const software = @import("software");

// Window size is measured against the content, not guessed: the card ends at
// y=187 and its shadow tail fades out by ~215, so anything past 216 is empty
// page. A window that dwarfs its content is the same mistake as a gradient
// that only covers half the frame -- a size nobody derived.
const W = 460;
const H = 216;

/// The app declaration the window composition binds to. Same shape as every
/// other example: title, size, state, and optionally the keys a `theme.zon`
/// may set that the library knows nothing about.
pub const app = .{
    .title = "elmz - glow, sdf vs baked",
    .theme_path = "theme.zon",
    .theme_tokens = Tokens,
    .size = .{ .w = W, .h = H },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

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

    // A gradient a theme file declares wins; a flat colour is the fallback.
    // That is the protocol in one line: the FILE decides the look, the code
    // only decides where the roles go.
    const page_fill = ui.gradients.get("bg") orelse elmz.Fill.angled(115, th.bg, th.panel);
    const card_fill = ui.gradients.get("panel") orelse elmz.Fill.vgrad(th.panel, th.bg);

    const shadow_color = elmz.Color{ .r = 0x08, .g = 0x07, .b = 0x0e, .a = 190 };
    const glow_color = elmz.Color{ .r = th.accent.r, .g = th.accent.g, .b = th.accent.b, .a = 120 };

    const title = ui.text(.{ .label = "glow + shadow", .size = m.title_size, .tone = .normal });

    const note = ui.text(.{
        .label = "the page gradient, the card shadow and the button glow are theme decisions. the pointer never reaches view, so the hover halo is derived during paint",
        .size = 12,
        .tone = .muted,
        .wrap = true,
        // W - 2*pad - card - gap, so the row ends exactly at the right pad.
        // Leaving the column to size itself put all the slack on one side and
        // the page looked off-centre for no reason anyone could name.
        .width = W - 2 * 28 - 200 - 16,
    });

    // Two buttons, identical in every visible respect -- same colour, same blur,
    // same spread -- differing ONLY in which renderer is asked for. `.auto`
    // would bake both; forcing `.sdf` on the left is deliberately the slow path,
    // which is the only way a side-by-side can show that the two paths agree.
    //
    // If they ever diverge, it will be here first: the stencil quantises
    // coverage to a byte and the distance field does not.
    const halo = elmz.Halo{ .color = glow_color, .blur = 14, .spread = 2, .mode = .glow };

    const sdf_button = ui.button(.{
        .label = "sdf",
        .msg = .primary,
        .key = 1,
        .width = 68,
        .style = .{
            .bg = th.accent,
            .fg = th.bg,
            .radius = 10,
            .halo = .{ .color = halo.color, .blur = halo.blur, .spread = halo.spread, .mode = halo.mode, .quality = .sdf },
        },
        // hover replaces the halo rather than adding one: a shadow sits UNDER
        // a thing, a glow spreads AROUND it, and the same element does not
        // want both at once.
        .hover_halo = .{ .color = glow_color, .blur = 18, .spread = 2, .mode = .glow },
    });

    const baked_button = ui.button(.{
        .label = "baked",
        .msg = .primary,
        .key = 2,
        .width = 68,
        .style = .{
            .bg = th.accent,
            .fg = th.bg,
            .radius = 10,
            // Same numbers, different path: one stencil built once and blitted,
            // instead of a distance field evaluated per pixel every frame.
            .halo = .{ .color = halo.color, .blur = halo.blur, .spread = halo.spread, .mode = halo.mode, .quality = .baked },
        },
        .hover_halo = .{ .color = glow_color, .blur = 18, .spread = 2, .mode = .glow },
    });

    // 24px apart: two 14px halos at an 8px gap overlap each other and read as one
    // blob, which defeats the point of putting them side by side at all.
    const buttons = ui.row(.{ .children = &.{ sdf_button, baked_button }, .gap = 24 });

    const card_inner = ui.column(.{
        .children = &.{
            ui.text(.{ .label = "a card with a shadow", .size = 14, .tone = .normal }),
            ui.spaceBefore(buttons, 16),
        },
    });
    const card = ui.column(.{
        .children = &.{card_inner},
        .width = 200,
        .style = .{
            .pad = 20,
            .bg_grad = card_fill,
            .radius = 14,
            .border = th.border,
            // spread gives the shadow a solid core; without it the falloff
            // starts at the edge and reads as a smudge, not an occlusion.
            .halo = .{ .color = shadow_color, .blur = 22, .spread = 3, .offset = .{ 0, 10 }, .mode = .shadow },
        },
    });

    const body = ui.row(.{ .children = &.{ note, ui.spaceBefore(card, 16) }, .width = W - 2 * 28 });

    // The root FILLS the window. Without a height it is content-sized, the
    // gradient stops at the content box, and the page gets a rectangular seam
    // where the ramp ends -- the sizing artefact, not a gradient bug.
    return ui.column(.{
        .children = &.{
            title,
            ui.spaceBefore(body, 24),
        },
        .width = W,
        .height = H,
        .style = .{
            .pad = 28,
            .bg_grad = page_fill,
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
        // Two stencils: the card's shadow, and ONE shared by both buttons --
        // they have identical geometry and blur, so the second bake is a cache
        // hit. The SDF button would add a third if it were not on the other path.
        try out.print("baked stencils in cache: {d} (card shadow + 1 shared by both buttons)\n", .{canvas.masks.items.len});
        for (f.hits) |h| {
            if (h.key) |k| {
                try out.print("  key {d}: x {d}..{d}, y {d}..{d}\n", .{ k, h.rect.x, h.rect.x + h.rect.w, h.rect.y, h.rect.y + h.rect.h });
            }
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
