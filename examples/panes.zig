//! A whole screen of the pre-widget pieces: a scrolling viewport with its
//! automatic thumb, tabs, one face at four sizes, baseline alignment, a haloed
//! popup, and a click on nothing dismissing it.
//!
//! Headless: `zig build run-panes` writes three PNGs.
//!
//!    panes.png           the Rows tab at rest
//!    panes-scrolled.png  the same list scrolled, thumb off the top
//!    panes-menu.png      the popup open
//!
//! The list is 24 rows in a 250-tall viewport, so it overflows by construction
//! and the thumb appears without the app asking for one. Nothing here sets a
//! scrollbar: the frame derives the thumb from content height over view height,
//! and the thumb carries a drag region of its own so the rows underneath stay
//! clickable everywhere else.
//!
//! One face, four sizes. `Font` is a VALUE type but the canvas holds exactly one
//! (`Canvas.setFont`), so "different fonts" in a single window is not something
//! this library can do yet -- per-element faces arrive with the font roadmap,
//! where a theme file names a face and the library resolves it. What is shown
//! here is the same face at 11 / 13 / 18 / 26, which is what a real screen's
//! hierarchy is built from anyway.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .font_path = "src/font.ttf",
    .title = "elmz - panes",
    .size = .{ .w = 720, .h = 520 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    // Wired through `@hasField` in runApp: an app that declares these hears
    // about them, an app that does not pays nothing.
    .on_key = onKey,
    .on_outside = onOutside,
};

const W = app.size.w;
const H = app.size.h;
const scroll_key: u64 = 900;
const rows: usize = 24;

pub const Msg = enum {
    tab_rows,
    tab_type,
    tab_notes,
    menu_open,
    menu_close,
    pick,
};

pub const Model = struct {
    tab: u8 = 0,
    menu: bool = false,
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .tab_rows => m.tab = 0,
        .tab_type => m.tab = 1,
        .tab_notes => m.tab = 2,
        .menu_open => m.menu = true,
        .menu_close => m.menu = false,
        .pick => return .{ .repaint = true },
    }
    return .{};
}

/// Escape closes the popup. The runtime owns Tab (it is the only thing that
/// knows document order); everything else is the app's to interpret.
pub fn onKey(m: *Model, k: elmz.Key, phase: elmz.Phase) ?Msg {
    if (phase != .down) return null;
    if (!m.menu) return null;
    if (k.named == .escape) return .menu_close;
    return null;
}

/// A press that claimed no region at all. This is the only press no element can
/// ever see, so it is the only way a popup can hear the click that dismisses it.
pub fn onOutside(m: *Model, _: [2]f32) ?Msg {
    if (m.menu) return .menu_close;
    return null;
}

/// A nav tab is a text element with a fill and padding, not a widget: the only
/// thing that makes it "selected" is which theme role it is painted with.
fn tab(ui: *elmz.Ui(Msg), label: []const u8, active: bool, msg: Msg, key: u64) *elmz.Element(Msg) {
    const e = ui.text(.{
        .label = label,
        .size = 13,
        .on_press = msg,
        .key = key,
        .style = .{
            .pad = 10,
            .radius = 8,
            .bg = if (active) ui.theme.selected else ui.theme.control,
            .fg = if (active) ui.theme.text else ui.theme.text_muted,
        },
    });
    // Focus is a plain field, not a builder option: it only matters to Tab,
    // which the runtime owns, so no call site has to spell it out.
    e.focusable = true;
    return e;
}

fn listRow(ui: *elmz.Ui(Msg), i: usize) *elmz.Element(Msg) {
    const name = ui.text(.{
        .label = ui.fmt("row {d:0>2}", .{i + 1}),
        .size = 13,
        .on_press = .pick,
        .key = 100 + i,
    });
    const meta = ui.text(.{ .label = ui.fmt("{d} prims", .{(i * 7) % 41}), .size = 11, .tone = .muted });
    return ui.row(.{ .children = &.{ name, ui.spaceBefore(meta, 10) }, .style = .{ .pad = 5, .radius = 6 } });
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const th = ui.theme;
    const accent_fill = ui.gradients.get("accent") orelse elmz.Fill.hgrad(th.accent, elmz.Color.rgbHex(0xf5c2e7));

    // -- header ------------------------------------------------------------
    const title = ui.text(.{ .label = "panes", .size = 30, .style = .{ .fg_grad = accent_fill } });
    const sub = ui.text(.{
        .label = "scroll, tabs, one face at four sizes, and a popup that dismisses on an outside click",
        .size = 12,
        .tone = .muted,
    });
    const head = ui.column(.{ .children = &.{ title, sub }, .gap = 2 });

    const nav = ui.row(.{ .children = &.{
        tab(ui, "Rows", m.tab == 0, .tab_rows, 1),
        tab(ui, "Type", m.tab == 1, .tab_type, 2),
        tab(ui, "Notes", m.tab == 2, .tab_notes, 3),
    }, .gap = 8 });

    // -- left: the viewport ------------------------------------------------
    // A definite height is what makes an overflow possible at all; without one
    // the viewport measures at its content and could never scroll.
    var rows_buf: [rows]*elmz.Element(Msg) = undefined;
    for (&rows_buf, 0..) |*r, i| r.* = listRow(ui, i);
    const list = ui.column(.{ .children = &rows_buf, .gap = 2 });

    const vp = ui.scroll(.{ .key = scroll_key, .child = list });
    vp.width = 300;
    vp.height = 268;
    vp.applyStyle(.{ .pad = 8, .bg = th.panel, .radius = 12, .border = th.border });

    // -- right: switches with the tab -------------------------------------
    const actions_head = ui.text(.{ .label = "actions", .size = 11, .tone = .muted });

    const primary = ui.button(.{ .label = "Open menu", .msg = .menu_open, .key = 4, .width = 200, .style = .{
        .bg_grad = accent_fill,
        .fg = th.text,
    } });
    const inert = ui.button(.{ .label = "Unavailable", .msg = .pick, .key = 5, .width = 200, .disabled = true });

    // Baseline, not box middles: a 26pt number and a 12pt caption share a
    // baseline, which is the alignment a line of type actually wants.
    const big = ui.text(.{ .label = "24", .size = 26 });
    const cap = ui.text(.{ .label = "rows in the list", .size = 12, .tone = .muted });
    const stats = ui.row(.{ .children = &.{ big, ui.spaceBefore(cap, 8) } });
    stats.row_align = .baseline;

    const panel: *elmz.Element(Msg) = switch (m.tab) {
        1 => ui.column(.{ .children = &.{
            ui.text(.{ .label = "four sizes, one face", .size = 26 }),
            ui.spaceBefore(ui.text(.{ .label = "18 - a section heading", .size = 18 }), 10),
            ui.spaceBefore(ui.text(.{ .label = "13 - body text, the size the list rows use", .size = 13 }), 8),
            ui.spaceBefore(ui.text(.{ .label = "11 - captions and metadata", .size = 11, .tone = .muted }), 8),
            ui.spaceBefore(ui.text(.{
                .label = "A second FACE is not reachable from here yet: the canvas holds one, so per-element type waits for the font roadmap.",
                .size = 11,
                .tone = .muted,
                .wrap = true,
            }), 14),
        }, .width = 340, .style = .{ .pad = 16, .bg = th.panel, .radius = 12, .border = th.border } }),
        2 => ui.column(.{ .children = &.{
            ui.text(.{ .label = "notes", .size = 18 }),
            ui.spaceBefore(ui.text(.{
                .label = "Wrapped text breaks at spaces and at newlines and is measured at the width it is given, so this paragraph reflows with the panel rather than running past it. A single word wider than the box is elided, not spilled.",
                .size = 13,
                .wrap = true,
            }), 10),
            ui.spaceBefore(stats, 16),
        }, .width = 340, .style = .{ .pad = 16, .bg = th.panel, .radius = 12, .border = th.border } }),
        else => ui.column(.{ .children = &.{
            actions_head,
            ui.spaceBefore(primary, 10),
            ui.spaceBefore(inert, 8),
            ui.spaceBefore(stats, 16),
            ui.spaceBefore(ui.text(.{
                .label = "The disabled button stays in the hit list with active = false, so a click cannot fall through to whatever is behind it.",
                .size = 11,
                .tone = .muted,
                .wrap = true,
            }), 12),
        }, .width = 340, .style = .{ .pad = 16, .bg = th.panel, .radius = 12, .border = th.border } }),
    };

    const body = ui.row(.{ .children = &.{ vp, ui.spaceBefore(panel, 16) }, .gap = 4 });

    const footer = ui.text(.{
        .label = "Tab walks the named controls; Escape or a click on empty space closes the menu",
        .size = 11,
        .tone = .muted,
    });

    const page = ui.column(.{ .children = &.{
        head,
        ui.spaceBefore(nav, 14),
        ui.spaceBefore(body, 14),
        ui.spaceBefore(footer, 14),
    }, .style = .{ .pad = 20 } });

    // -- the popup ---------------------------------------------------------
    // A ZERO-HEIGHT stack is the overlay idiom: it takes no space in the flow,
    // its children still paint and still claim, and the offset says where.
    const pop = ui.column(.{ .children = &.{
        popupItem(ui, "Duplicate", 31),
        popupItem(ui, "Rename", 32),
        popupItem(ui, "Remove", 33),
    }, .gap = 2, .style = .{ .pad = 8, .bg = th.panel, .radius = 10, .border = th.border } });
    pop.width = 190;
    pop.offset = .{ 386, 120 };
    pop.halo = .{ .color = th.bg, .offset = .{ 0, 6 }, .blur = 16, .mode = .outer_glow };

    var kids: [2]*elmz.Element(Msg) = undefined;
    kids[0] = page;
    var n: usize = 1;
    if (m.menu) {
        kids[1] = pop;
        n = 2;
    }

    const root = ui.stack(.{ .children = kids[0..n] });
    root.width = W;
    root.height = H;
    return root;
}

fn popupItem(ui: *elmz.Ui(Msg), label: []const u8, key: u64) *elmz.Element(Msg) {
    const e = ui.text(.{
        .label = label,
        .size = 13,
        .on_press = .pick,
        .key = key,
        .style = .{ .pad = 8, .radius = 6 },
    });
    e.focusable = true;
    return e;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);
    // Owned by us: loadFont hands back the file bytes and nothing else frees
    // them. The defer order matters -- the canvas is torn down first, since it
    // holds a slice into these bytes.
    const font_bytes = try software.loadFont(gpa, io, "src/font.ttf");
    defer gpa.free(font_bytes);
    canvas.setFont(font_bytes);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "panes.png");
        try out.print("panes.png          {d} primitives, {d} hit regions\n", .{ f.prims.len, f.hits.len });
        // The thumb is painted last and carries a drag region of its own; if
        // scrolling regressed, this is where it shows up.
        var thumb = false;
        for (f.hits) |h| {
            if (h.drag != null) thumb = true;
        }
        try out.print("scrollbar thumb    {s}\n", .{if (thumb) "present as a drag region" else "MISSING"});
        // Content taller than the view is the whole reason a scrollbar exists.
        for (f.hits) |h| {
            if (h.scroll) |sv| {
                try out.print("viewport           content {d} over view {d}\n", .{ sv.content_h, sv.view_h });
            }
        }
    }

    // Scrolled: the thumb moves, the rows move, nothing else does.
    rt.scrollBy(scroll_key, 130);
    {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "panes-scrolled.png");
        try out.print("panes-scrolled.png {d} primitives, offset {d}\n", .{ f.prims.len, rt.scrollOffset(scroll_key) });
    }

    // The popup, open. It paints above the page and claims before nothing else
    // gets a look at the pointer.
    rt.state.menu = true;
    {
        var f = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer f.deinit();
        try canvas.writePng(io, gpa, "panes-menu.png");
        try out.print("panes-menu.png     {d} primitives, {d} hit regions\n", .{ f.prims.len, f.hits.len });
    }

    try out.flush();
}
