//! A second example: a three-view gallery, still only text / quad / bar.
//!
//! Headless by default — writes `gallery_*.png` plus a contact sheet — so the
//! exact pixels can be inspected without a display. `gallery_window.zig` puts
//! this same app in an SDL3 window.
//!
//! Font note: 5x7 bitmap, integer scale only. Sizes snap to 7 / 14 / 21 / 28 px
//! and lowercase is drawn as uppercase. There are no glyphs for , _ ' or a
//! middot, so the copy avoids them.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .title = "elmz gallery",
    // Opts into the runner's theme watch: drop a theme.zon next to the
    // binary and the palette reloads on save.
    .theme_path = "theme.zon",
    .size = .{ .w = 380, .h = 330 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

pub const W = app.size.w;
pub const H = app.size.h;

const names = [_][]const u8{ "bananas", "tortillas", "peanut butter", "coffee" };

pub const Tab = enum { overview, list, about };

pub const Model = struct {
    tab: Tab = .overview,
    selected: usize = 1,
    level: i32 = 4,
    clicks: u32 = 0,
};

pub const Msg = union(enum) {
    tab: Tab,
    select: usize,
    inc,
    dec,
    reset,
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    m.clicks += 1;
    switch (msg) {
        .tab => |t| m.tab = t,
        .select => |i| m.selected = i,
        .inc => m.level = @min(10, m.level + 1),
        .dec => m.level = @max(0, m.level - 1),
        .reset => m.level = 0,
    }
    return .{};
}

fn navButton(ui: *elmz.Ui(Msg), label: []const u8, t: Tab, active: bool) !*elmz.Element(Msg) {
    const b = ui.button(.{ .label = label, .msg = .{ .tab = t }, .style = .{ .border = if (active) ui.theme.accent else ui.theme.border } });
    if (active) b.bg = ui.theme.selected;
    return b;
}

fn overviewBody(ui: *elmz.Ui(Msg), m: *Model) !*elmz.Element(Msg) {
    const controls = ui.row(.{ .children = &.{
        ui.button(.{ .label = "-", .msg = .dec }),
        ui.button(.{ .label = "+", .msg = .inc }),
        ui.button(.{ .label = "reset", .msg = .reset }),
    }, .gap = 8 });

    const meter = ui.bar(.{ .value = @as(f32, @floatFromInt(m.level)) / 10.0, .height = 12 });

    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "PRIMITIVES", .size = 10, .tone = .muted }),
        ui.text(.{ .label = "text / quad / bar", .size = 14 }),
        ui.spaceBefore(ui.textFmt("level {d} of 10", .{m.level}, 14), 6),
        meter,
        ui.spaceBefore(controls, 10),
    } });
}

fn listBody(ui: *elmz.Ui(Msg), m: *Model) !*elmz.Element(Msg) {
    var rows: [names.len]*elmz.Element(Msg) = undefined;
    for (names, 0..) |name, i| {
        const selected = i == m.selected;

        // A 4px accent block doubles as the selection marker: `bar` with a
        // width override is the only way to draw a small solid quad.
        const marker = ui.bar(.{ .value = 1, .width = 4, .height = 14 });
        if (!selected) marker.bg = ui.theme.panel;

        // A conditional tint is an optional: unset means "whatever the theme
        // says", so the selected row and the plain row are one construction.
        const line = ui.row(.{ .children = &.{ marker, ui.textFmt("{d}   {s}", .{ i + 1, name }, 14) }, .gap = 10, .on_press = .{ .select = i }, .style = .{
            .pad = 8,
            .bg = if (selected) ui.theme.selected else null,
            .border = if (selected) ui.theme.accent else null,
        } });

        rows[i] = line;
    }

    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "A LIST", .size = 10, .tone = .muted }),
        ui.spaceBefore(rows[0], 2),
        rows[1],
        rows[2],
        rows[3],
        ui.spaceBefore(ui.textFmt("selected {s}", .{names[m.selected]}, 10), 4),
    } });
}

fn aboutBody(ui: *elmz.Ui(Msg)) !*elmz.Element(Msg) {
    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "HOW IT WORKS", .size = 10, .tone = .muted }),
        ui.text(.{ .label = "NO RETAINED TREE", .size = 14 }),
        ui.spaceBefore(ui.text(.{ .label = "view returns a tree of values.", .size = 10, .tone = .muted }), 4),
        ui.text(.{ .label = "no widgets; just elements, gaps, pads.", .size = 10, .tone = .muted }),
        ui.text(.{ .label = "layout measures it, paint emits", .size = 10, .tone = .muted }),
        ui.text(.{ .label = "quads and text, and the backend", .size = 10, .tone = .muted }),
        ui.text(.{ .label = "turns those into pixels.", .size = 10, .tone = .muted }),
        ui.text(.{ .label = "nothing survives the frame.", .size = 10, .tone = .muted }),
    } });
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const nav = ui.row(.{ .children = &.{
        try navButton(ui, "overview", .overview, m.tab == .overview),
        try navButton(ui, "list", .list, m.tab == .list),
        try navButton(ui, "about", .about, m.tab == .about),
    }, .gap = 8 });

    const body = switch (m.tab) {
        .overview => try overviewBody(ui, m),
        .list => try listBody(ui, m),
        .about => try aboutBody(ui),
    };

    const panel = ui.column(.{ .children = &.{body}, .gap = 6, .style = .{ .pad = 16, .bg = ui.theme.panel, .border = ui.theme.border } });

    const root = ui.column(.{ .children = &.{
        ui.text(.{ .label = "ELMZ GALLERY", .size = 22 }),
        ui.text(.{ .label = "a runtime above its backend", .size = 10, .tone = .muted }),
        ui.spaceBefore(nav, 8),
        ui.spaceBefore(panel, 6),
        ui.spaceBefore(ui.textFmt("clicks {d}   view {s}   level {d}", .{
            m.clicks, @tagName(m.tab), m.level,
        }, 10), 8),
    }, .gap = 4, .style = .{ .pad = 22 } });
    return root;
}

pub fn main(init: std.process.Init) !void {
    // `start.zig` has already built the general purpose allocator (leak checking
    // included, in Debug) and the IO runtime. Constructing our own only
    // duplicated them -- this is where five copies of `std.Io.Threaded.init`
    // came from, in a program that never wanted a thread.
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var out_buf = std.Io.File.stdout().writer(io, &buf);
    const out = &out_buf.interface;

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

    const shots = [_]Model{
        .{ .tab = .overview, .level = 4, .clicks = 3 },
        .{ .tab = .overview, .level = 8, .clicks = 9 },
        .{ .tab = .list, .selected = 2, .clicks = 14 },
        .{ .tab = .about, .clicks = 21 },
    };

    const gap: u32 = 12;
    var sheet = try software.Canvas.init(gpa, (W + gap) * shots.len + gap, H + 2 * gap);
    // By NAME, the way an app names a face in its theme: whichever face this
    // machine has, or none. With no fonts installed every example still runs and
    // the text falls back to the built-in bitmap face.
    const sheet_bytes = software.loadFontByName(gpa, init.io, "DejaVu Sans", &.{}) catch null;
    defer if (sheet_bytes) |fb| gpa.free(fb);
    if (sheet_bytes) |fb| sheet.setFont(fb);
    defer sheet.deinit();
    sheet.clear(elmz.Color.rgbHex(0x0b0d12));

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    for (shots, 0..) |state, i| {
        rt.state = state;
        var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer frame.deinit();

        try out.print("shot {d}: tab={s} level={d} prims={d} hits={d}\n", .{
            i, @tagName(state.tab), state.level, frame.primitiveCount(), frame.hits.len,
        });

        // text overflow check: the layout measures with real glyph metrics, so
        // anything painted past the window edge means a metric mismatch.
        for (frame.prims) |p| switch (p) {
            .text => |t| {
                const scale: f32 = @max(1, @round(t.size / 7));
                const drawn_w = @as(f32, @floatFromInt(t.bytes.len)) * 6 * scale - scale;
                const drawn_h = 7 * scale;
                if (t.x + drawn_w > @as(f32, @floatFromInt(W)) - 1 or
                    t.y + drawn_h > @as(f32, @floatFromInt(H)) - 1)
                {
                    try out.print("  OVERFLOW \"{s}\" x={d:.0} w={d:.0} y={d:.0} h={d:.0}\n", .{
                        t.bytes, t.x, drawn_w, t.y, drawn_h,
                    });
                }
            },
            else => {},
        };

        for (frame.hits, 0..) |h, j| {
            if (h.rect.x < 0 or h.rect.y < 0 or
                h.rect.x + h.rect.w > @as(f32, @floatFromInt(W)) or
                h.rect.y + h.rect.h > @as(f32, @floatFromInt(H)))
            {
                try out.print("  hit {d} out of bounds: {d:.0},{d:.0} {d:.0}x{d:.0}\n", .{
                    j, h.rect.x, h.rect.y, h.rect.w, h.rect.h,
                });
            }
        }

        sheet.blitFrom(&canvas, .{ gap + @as(u32, @intCast(i)) * (W + gap), gap });

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "gallery_{d}.png", .{i});
        try canvas.writePng(io, gpa, name);
    }

    try sheet.writePng(io, gpa, "gallery-sheet.png");

    try out.print("wrote gallery_0..{d}.png and gallery-sheet.png\n", .{shots.len - 1});
    try out.flush();
}
