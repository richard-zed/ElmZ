//! A whole screen: layout, panels, gradients, live theme, hit regions, keys,
//! a disabled control, and the error band.
//!
//! Headless: `zig build run-showcase` writes three PNGs.
//!
//!    showcase.png        the screen as it renders from the compiled defaults
//!    showcase-hover.png  the same screen with the pointer parked dead-centre
//!                        on a keyed button -- the hover fill is DERIVED from
//!                        that position, not set on the element
//!    showcase-error.png  ONLY when a theme file exists and will not parse: the
//!                        band carrying the loader's own file:line diagnostic
//!
//! Both frames come from the same chain the runner resolves -- `theme.zon` over
//! `theme.defaults.zon` over the library's palette -- so a recoloured screen
//! here is a recoloured screen in a window. The sample beside this file is a
//! starting point:
//!
//!     cp examples/showcase.theme.zon theme.zon && zig build run-showcase

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .title = "elmz - showcase",
    .size = .{ .w = 640, .h = 470 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    // Optional. Both halves read the same file: headless loads it directly,
    // and the runner watches it for the -sdl3 variant, so editing a colour
    // recolours the running window.
    .theme_path = @as(?[]const u8, "theme.zon"),
};

const W = app.size.w;
const H = app.size.h;

pub const Msg = enum {
    tab_files,
    tab_activity,
    tab_settings,
    primary,
    pick_a,
    pick_b,
    pick_c,
};

pub const Model = struct {
    tab: u8 = 1,
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .tab_files => m.tab = 0,
        .tab_activity => m.tab = 1,
        .tab_settings => m.tab = 2,
        .primary, .pick_a, .pick_b, .pick_c => {},
    }
    return .{};
}

/// A nav tab is a text element with a fill and padding -- not a widget. The
/// only thing that makes it "selected" is which theme role it is filled with.
fn tab(ui: *elmz.Ui(Msg), label: []const u8, active: bool, msg: Msg, key: u64) *elmz.Element(Msg) {
    const e = ui.text(label, 14);
    e.pad = 11;
    e.radius = 8;
    e.bg = if (active) ui.theme.selected else ui.theme.control;
    e.fg = if (active) ui.theme.text else ui.theme.text_muted;
    e.on_press = msg;
    e.key = key;
    return e;
}

fn listRow(ui: *elmz.Ui(Msg), label: []const u8, meta: []const u8, msg: Msg, key: u64) *elmz.Element(Msg) {
    const name = ui.text(label, 14);
    name.key = key;
    name.on_press = msg;

    const note = ui.muted(meta, 11);

    const row = ui.row(&.{ name, ui.spaceBefore(note, 10) });
    row.pad = 6;
    row.radius = 6;
    return row;
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const th = ui.theme;
    const pink = elmz.Color.rgbHex(0xf5c2e7);
    const green = elmz.Color.rgbHex(0xa6e3a1);

    // -- header ------------------------------------------------------------
    const title = ui.text("elmz", 28);
    title.fg_grad = elmz.Fill.hgrad(th.accent, pink);

    const sub = ui.muted("one frame: layout, fills, states, keys, theme", 12);

    const head = ui.column(&.{ title, sub });
    head.gap = 2;

    // -- nav ---------------------------------------------------------------
    const nav = ui.row(&.{
        tab(ui, "Files", m.tab == 0, .tab_files, 1),
        tab(ui, "Activity", m.tab == 1, .tab_activity, 2),
        tab(ui, "Settings", m.tab == 2, .tab_settings, 3),
    });
    nav.gap = 8;

    // -- left card: a list where every row is its own hit region -----------
    const card_head = ui.text("recent", 12);
    card_head.fg = th.text_muted;

    const rows = ui.column(&.{
        listRow(ui, "counter.zig", "12 prims", .pick_a, 10),
        listRow(ui, "tasks.zig", "38 prims", .pick_b, 11),
        listRow(ui, "gallery.zig", "37 prims", .pick_c, 12),
    });
    rows.gap = 2;

    const progress = ui.bar(0.62);
    progress.width = 308;
    progress.height = 12;
    progress.radius = 6;
    progress.fg_grad = elmz.Fill.hgrad(th.accent, green);

    const usage = ui.muted("62% of a week of frames", 11);

    const left = ui.column(&.{
        card_head,
        ui.spaceBefore(rows, 10),
        ui.spaceBefore(progress, 14),
        ui.spaceBefore(usage, 8),
    });
    left.pad = 16;
    left.width = 340;
    left.bg = th.panel;
    left.radius = 12;
    left.border = th.border;

    // -- right card: actions, one of them inert ----------------------------
    const actions_head = ui.text("actions", 12);
    actions_head.fg = th.text_muted;

    const primary = ui.button("Sync now", .primary);
    primary.key = 4;
    primary.width = 188;
    primary.bg_grad = elmz.Fill.hgrad(th.control, th.selected);
    primary.fg = th.text;

    const inert = ui.button("Unavailable", .primary);
    inert.key = 5;
    inert.width = 188;
    inert.disabled = true;

    const inert_note = ui.muted(
        "the second button stays in the hit list with active = false, so a click cannot land on whatever is behind it",
        11,
    );
    inert_note.wrap = true;
    inert_note.width = 188;

    const right = ui.column(&.{
        actions_head,
        ui.spaceBefore(primary, 10),
        ui.spaceBefore(inert, 8),
        ui.spaceBefore(inert_note, 12),
    });
    right.pad = 16;
    right.width = 216;
    right.bg = th.panel;
    right.radius = 12;
    right.border_grad = elmz.Fill.hgrad(pink, th.accent);

    // -- body and page -----------------------------------------------------
    const body = ui.row(&.{ left, right });
    body.gap = 16;

    const footer = ui.muted("frames: showcase.png, showcase-hover.png, showcase-error.png", 11);

    const root = ui.column(&.{
        head,
        ui.spaceBefore(nav, 16),
        ui.spaceBefore(body, 14),
        ui.spaceBefore(footer, 16),
    });
    root.pad = 24;
    return root;
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

    // The theme chain, resolved exactly as the runner resolves it: a
    // `theme.zon` override over a `theme.defaults.zon` base over the library's
    // own palette. Files live beside the binary, not in the cwd -- the cwd is
    // only wherever this happened to be launched from.
    var theme_name: []const u8 = "compiled defaults";
    var theme_failed = false;

    var base_owned: ?[:0]u8 = null;
    var user_owned: ?[:0]u8 = null;
    defer if (base_owned) |bp| gpa.free(bp);
    defer if (user_owned) |up| gpa.free(up);
    base_owned = runner.themePathBesideExe(gpa, io, "theme.defaults.zon");
    user_owned = runner.themePathBesideExe(gpa, io, "theme.zon");

    const chain = runner.resolveChain(gpa, io, .{}, base_owned, user_owned);
    rt.ui.theme = chain.theme;
    if (chain.base_from_file) theme_name = "theme.defaults.zon";
    if (chain.user_from_file) theme_name = "theme.zon";
    if (chain.message()) |m| {
        // The file is present and wrong. Keep the last good palette on screen
        // and raise the band -- this is the only path that draws it, because a
        // band with nothing to report is just a red stripe.
        rt.ui.failExternal(.theme, "{s}", .{m});
        theme_failed = true;
        theme_name = if (chain.user_rejected)
            "base (theme.zon rejected)"
        else
            "compiled (theme.defaults.zon rejected)";
    }

    // -- frame one: resting state -----------------------------------------
    var button_rect: ?elmz.Rect = null;
    {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "showcase.png");
        // Find the primary button the way the pointer would: by its key.
        for (f.hits) |h| {
            if (h.key == 4) button_rect = h.rect;
        }
        try out.print("showcase.png      {d} primitives, {d} hit regions, theme: {s}\n", .{
            f.prims.len, f.hits.len, theme_name,
        });
    }

    // -- frame two: the pointer over the primary button --------------------
    if (button_rect) |r| {
        rt.pointer.pos = .{ r.x + r.w / 2, r.y + r.h / 2 };
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "showcase-hover.png");
        // The hovered element paints a different fill, so the primitive count
        // is unchanged but the colours are not -- say which, honestly.
        const under = f.hit(rt.pointer.pos.?);
        try out.print("showcase-hover.png{d:>6} primitives, pointer over key {?d}\n", .{
            f.prims.len, if (under) |h| h.key else null,
        });
    }
    rt.pointer.pos = null;

    // -- frame three: only if something actually went wrong ----------------
    //
    // No contrived bad source string here. If `theme.zon` loaded, there is no
    // error to show and no third PNG: the band is a report, not a decoration.
    if (theme_failed) {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "showcase-error.png");
        try out.print("showcase-error.png{d:>6} primitives, band reads: {s}\n", .{
            f.prims.len, chain.diag.text(),
        });
    } else {
        try out.print("no showcase-error.png: theme loaded, nothing to report\n", .{});
    }

    try out.flush();
}
