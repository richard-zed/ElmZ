//! Glow and shadow, in every shape the library has: the three cuts of one ramp,
//! the two renderers behind it, and the same ramp thrown as a shadow.
//!
//! Four things, in order of how much they cost:
//!
//!   1. a GRADIENT BACKGROUND, built from theme tokens rather than literals,
//!      so a `theme.zon` recolours the room as well as the furniture;
//!   2. TWO BUTTONS THAT ARE THE SAME BUTTON -- one asking the distance field
//!      for its halo and one asking for a baked stencil. Same blur, same spread,
//!      same colour: if the two renderers ever disagree, a person sees both in
//!      one glance instead of having to remember the last one. The pixel-level
//!      agreement claim lives in the test suite, not in the eye;
//!   3. THREE CUTS OF ONE RAMP. `glow` straddles the edge, so half the ramp
//!      lands ON the shape -- light wraps a face, it does not avoid it.
//!      `outer_glow` is that ramp cut against the ELEMENT, so nothing tints the
//!      face. `inner_glow` is the mirrored ramp cut inward: a lit rim with a
//!      dark centre. Colour, blur and spread are identical across the three, so
//!      the only variable on screen is the cut;
//!   4. A SHADOW FAN. `Halo.shadow` derives the offset FROM the light, so a
//!      shadow cannot point the wrong way for its own light -- the one
//!      combination with no use. The angle is where the light comes FROM,
//!      clockwise from "to the right"; the shadow falls opposite.
//!
//! Worth knowing while looking: a lit halo cannot be a baked stencil. The mask
//! is keyed on the silhouette alone and a light changes the mask's CONTENTS,
//! so lit halos take the distance-field path and `quality = .baked` does not
//! override it. The printed stencil count is how that shows up, and it is why
//! the shadow row costs what it costs.
//!
//! Everything here is tokens plus geometry. There is not a single hex literal in
//! `view` that is not an alpha ramp, which is the whole point of a theme
//! protocol: swap the file, get a different picture, change no code.

const std = @import("std");
const elmz = @import("elmz");
const runner = @import("runner");
const software = @import("software");

// Sized against the content: the deepest shadow tail is dist + spread +
// blur/2 = 10 + 2 + 9 = 21px past a card, and the page pad is 26. A window that
// dwarfs its content is the same mistake as a gradient that only covers half the
// frame -- a size nobody derived.
const W = 620;
const H = 484;

/// The app declaration the window composition binds to. Same shape as every
/// other example: title, size, state, and optionally the keys a `theme.zon` may
/// set that the library knows nothing about.
pub const app = .{
    .title = "elmz - glow, shadow, and the three cuts",
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
/// about. Declaring the struct is what makes the keys checkable -- an undeclared
/// key is a parse error, not a silently ignored line.
pub const Tokens = struct {
    title_size: f32 = 30,
};

fn update(_: *Model, _: Msg) elmz.Action(Msg) {
    return .{};
}

fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const th = ui.theme;

    // A gradient a theme file declares wins; a flat colour is the fallback. That
    // is the protocol in one line: the FILE decides the look, the code only
    // decides where the roles go.
    const page_fill = ui.gradients.get("bg") orelse elmz.Fill.angled(205, th.bg, th.panel);

    const shadow_color = elmz.Color{ .r = 0x08, .g = 0x07, .b = 0x0e, .a = 190 };
    // Alpha, not a tinted token: a halo is additive-looking light, and an opaque
    // one hides the shape it is supposedly lighting.
    const glow_color = elmz.Color{ .r = th.accent.r, .g = th.accent.g, .b = th.accent.b, .a = 130 };

    // Hover for the renderer pair changes the TINT and never the geometry.
    // Growing the halo on hover is a fine thing to demo, but not here: it would
    // make one of the two renderers look larger for a reason that has nothing
    // to do with rendering, and a size difference is exactly what someone
    // comparing the two paths would read as "the stencil is bigger".
    const glow_hot = elmz.Color{ .r = th.accent.r, .g = th.accent.g, .b = th.accent.b, .a = 210 };

    const title = ui.text(.{ .label = "glow + shadow", .size = m.title_size, .tone = .normal });

    const note = ui.text(.{
        .label = "the page gradient, the shadows and every glow are theme decisions. the pointer never reaches view, so a hover halo is derived during paint.",
        .size = 12,
        .tone = .muted,
        .wrap = true,
        .width = 470,
    });

    // -- same halo, two renderers -------------------------------------------
    // Identical in every visible respect -- same colour, same blur, same spread
    // -- differing ONLY in which renderer is asked for. Leaving the default
    // alone would bake both; forcing `.sdf` is deliberately the slow path, which
    // is the only way a side-by-side can show that the two paths agree.
    //
    // If they ever diverge it will be here first: the stencil quantises coverage
    // to a byte and the distance field does not.
    const sdf_button = ui.button(.{
        .label = "sdf",
        .msg = .primary,
        .key = 1,
        .width = 74,
        .style = .{
            .bg = th.accent,
            .fg = th.bg,
            .radius = 10,
            .halo = .{ .color = glow_color, .blur = 14, .spread = 2, .mode = .glow, .quality = .sdf },
        },
        // hover REPLACES the halo rather than adding one: a shadow sits under a
        // thing, a glow spreads around it, and the same element does not want
        // both at once.
        .hover_halo = .{ .color = glow_hot, .blur = 14, .spread = 2, .mode = .glow },
    });

    const baked_button = ui.button(.{
        .label = "baked",
        .msg = .primary,
        .key = 2,
        .width = 74,
        .style = .{
            .bg = th.accent,
            .fg = th.bg,
            .radius = 10,
            // Same numbers, different path: one stencil built once and blitted,
            // instead of a distance field evaluated per pixel every frame.
            .halo = .{ .color = glow_color, .blur = 14, .spread = 2, .mode = .glow, .quality = .baked },
        },
        .hover_halo = .{ .color = glow_hot, .blur = 14, .spread = 2, .mode = .glow },
    });

    // 24px apart: two 14px halos at an 8px gap overlap each other and read as one
    // blob, which defeats the point of putting them side by side at all.
    const renderer_row = ui.row(.{ .children = &.{ sdf_button, baked_button }, .gap = 24 });

    // -- three cuts of one ramp ---------------------------------------------
    // An inner rim is not an outward glow seen backwards: it sits ON the face, so
    // a saturated accent at the outward alpha reads as a hard ring painted on the
    // button rather than light landing on it. The outward cuts keep the accent;
    // the inner one gets a light tint at low alpha and a wider, slower falloff, so
    // it reads as a sheen. This breaks the row's "only `mode` differs" invariant on
    // purpose -- compare the CUT here, judge the colour on this one button.
    const inner_color = elmz.Color{ .r = th.text.r, .g = th.text.g, .b = th.text.b, .a = 48 };
    const modes = [_]elmz.Halo.Mode{ .glow, .outer_glow, .inner_glow };
    const mode_names = [_][]const u8{ "glow", "outer_glow", "inner_glow" };
    var mode_buttons: [modes.len]*elmz.Element(Msg) = undefined;
    for (modes, 0..) |mode, i| {
        mode_buttons[i] = ui.button(.{
            .label = mode_names[i],
            .msg = .primary,
            .key = i + 3,
            .width = 124,
            .style = .{
                .bg = th.control,
                .fg = th.text,
                .radius = 10,
                // Identical in every field except `mode`, so a difference on
                // screen is the cut and nothing else.
                .halo = if (mode == .inner_glow)
                    .{ .color = inner_color, .blur = 20, .spread = 2, .mode = mode }
                else
                    .{ .color = glow_color, .blur = 16, .spread = 3, .mode = mode },
            },
            .hover_halo = if (mode == .inner_glow)
                .{ .color = elmz.Color{ .r = th.text.r, .g = th.text.g, .b = th.text.b, .a = 78 }, .blur = 26, .spread = 3, .mode = mode }
            else
                .{ .color = glow_color, .blur = 24, .spread = 5, .mode = mode },
        });
    }
    const mode_row = ui.row(.{ .children = &mode_buttons, .gap = 20 });

    // -- one ramp, thrown ---------------------------------------------------
    // Same blur, same spread, same colour; only the light moves. 0 is overhead
    // and is the one a UI wants almost always. Labelled by side rather than by
    // angle: a number cannot say which way the light comes from, which is what
    // made this fan unreadable when it said "270", "45", "90" -- and worse, the
    // labels had stopped matching the lights they sat on.
    const lights = [_]f32{ 0, 90, 135, 180, 270 };
    const light_names = [_][]const u8{ "above", "right", "lower-right", "below", "left" };
    var cards: [lights.len]*elmz.Element(Msg) = undefined;
    for (lights, 0..) |deg, i| {
        const label = ui.text(.{ .label = light_names[i], .size = 12, .tone = .muted });
        cards[i] = ui.column(.{
            .children = &.{label},
            .width = 88,
            .height = 54,
            .style = .{
                .pad = 10,
                .bg = th.panel,
                .radius = 10,
                .border = th.border,
                // The offset is derived inside `shadow`, so the two cannot
                // disagree.
                .halo = elmz.Halo.shadow(shadow_color, deg, 10),
            },
        });
    }
    const fan_row = ui.row(.{ .children = &cards, .gap = 22 });

    const body = ui.column(.{ .children = &.{
        title,
        ui.spaceBefore(note, 18),
        ui.spaceBefore(ui.text(.{ .label = "same halo, two renderers", .size = 15 }), 26),
        ui.spaceBefore(renderer_row, 14),
        ui.spaceBefore(ui.text(.{ .label = "one ramp, three cuts", .size = 15 }), 30),
        ui.spaceBefore(mode_row, 14),
        ui.spaceBefore(ui.text(.{ .label = "one ramp, thrown", .size = 15 }), 30),
        ui.spaceBefore(fan_row, 14),
    } });

    // The root FILLS the window. Without a height it is content-sized, the
    // gradient stops at the content box, and the page gets a rectangular seam
    // where the ramp ends -- the sizing artefact, not a gradient bug.
    return ui.column(.{
        .children = &.{body},
        .width = W,
        .height = H,
        .style = .{
            .pad = 26,
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

    // Caller-owned bytes: the canvas holds a slice into them, so the
    // free is registered first and therefore runs after the teardown.
    // By NAME, the way an app names a face in its theme: whichever face this
    // machine has, or none. With no fonts installed every example still runs and
    // the text falls back to the built-in bitmap face.
    const font_bytes = software.loadFontByName(gpa, init.io, "DejaVu Sans", &.{}) catch null;
    defer if (font_bytes) |fb| gpa.free(fb);
    if (font_bytes) |fb| canvas.setFont(fb);
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

    var baked_rect: ?elmz.Rect = null;
    var rest_halos: usize = 0;

    // -- frame one: at rest ------------------------------------------------
    {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "glow.png");
        rest_halos = countHalos(f.prims);
        try out.print("glow.png        {d} primitives, {d} halo(s), theme: {s}\n", .{ f.prims.len, rest_halos, name });
        // Every halo in the fan is lit, so none of them can be a stencil. That
        // number is a rendering decision that is otherwise invisible.
        try out.print("baked stencils: {d} (lit halos cannot bake -- the light changes the mask)\n", .{canvas.masks.items.len});
        for (f.hits) |h| {
            if (h.key) |k| {
                try out.print("  key {d}: x {d}..{d}, y {d}..{d}\n", .{ k, h.rect.x, h.rect.x + h.rect.w, h.rect.y, h.rect.y + h.rect.h });
            }
            if (h.key == 2) baked_rect = h.rect;
        }
    }

    // -- frame two: the pointer over the baked button ----------------------
    if (baked_rect) |r| {
        rt.pointer.pos = .{ r.x + r.w / 2, r.y + r.h / 2 };
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "glow-hover.png");
        // The halo is STILL one per element -- hover swaps which halo, it does
        // not stack a second one. A count that rose would mean the hover path
        // draws both, which no eye would catch on a matching colour.
        try out.print("glow-hover.png  {d} primitives, {d} halo(s), hover on key {?d}\n", .{
            f.prims.len,
            countHalos(f.prims),
            if (f.hit(rt.pointer.pos.?)) |h| h.key else null,
        });
        try out.print("halo count unchanged by hover: {s}\n", .{if (countHalos(f.prims) == rest_halos) "yes" else "NO"});
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
