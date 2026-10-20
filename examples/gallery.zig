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
    const b = ui.button(label, .{ .tab = t });
    b.border = if (active) ui.theme.accent else ui.theme.border;
    if (active) b.bg = ui.theme.selected;
    return b;
}

fn overviewBody(ui: *elmz.Ui(Msg), m: *Model) !*elmz.Element(Msg) {
    const controls = ui.row(&.{
        ui.button("-", .dec),
        ui.button("+", .inc),
        ui.button("reset", .reset),
    });
    controls.gap = 8;

    const meter = ui.bar(@as(f32, @floatFromInt(m.level)) / 10.0);
    meter.height = 12;

    return ui.column(&.{
        ui.muted("PRIMITIVES", 10),
        ui.text("text / quad / bar", 14),
        ui.spaceBefore(ui.textFmt("level {d} of 10", .{m.level}, 14), 6),
        meter,
        ui.spaceBefore(controls, 10),
    });
}

fn listBody(ui: *elmz.Ui(Msg), m: *Model) !*elmz.Element(Msg) {
    var rows: [names.len]*elmz.Element(Msg) = undefined;
    for (names, 0..) |name, i| {
        const selected = i == m.selected;

        // A 4px accent block doubles as the selection marker: `bar` with a
        // width override is the only way to draw a small solid quad.
        const marker = ui.bar(1);
        marker.width = 4;
        marker.height = 14;
        if (!selected) marker.bg = ui.theme.panel;

        const line = ui.row(&.{ marker, ui.textFmt("{d}   {s}", .{ i + 1, name }, 14) });
        line.pad = 8;
        line.gap = 10;
        line.on_press = .{ .select = i };
        if (selected) {
            line.bg = ui.theme.selected;
            line.border = ui.theme.accent;
        }

        rows[i] = line;
    }

    return ui.column(&.{
        ui.muted("A LIST", 10),
        ui.spaceBefore(rows[0], 2),
        rows[1],
        rows[2],
        rows[3],
        ui.spaceBefore(ui.textFmt("selected {s}", .{names[m.selected]}, 10), 4),
    });
}

fn aboutBody(ui: *elmz.Ui(Msg)) !*elmz.Element(Msg) {
    return ui.column(&.{
        ui.muted("HOW IT WORKS", 10),
        ui.text("NO RETAINED TREE", 14),
        ui.spaceBefore(ui.muted("view returns a tree of values.", 10), 4),
        ui.muted("no widgets; just elements, gaps, pads.", 10),
        ui.muted("layout measures it, paint emits", 10),
        ui.muted("quads and text, and the backend", 10),
        ui.muted("turns those into pixels.", 10),
        ui.muted("nothing survives the frame.", 10),
    });
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const nav = ui.row(&.{
        try navButton(ui, "overview", .overview, m.tab == .overview),
        try navButton(ui, "list", .list, m.tab == .list),
        try navButton(ui, "about", .about, m.tab == .about),
    });
    nav.gap = 8;

    const body = switch (m.tab) {
        .overview => try overviewBody(ui, m),
        .list => try listBody(ui, m),
        .about => try aboutBody(ui),
    };

    const panel = ui.column(&.{body});
    panel.pad = 16;
    panel.gap = 6;
    panel.bg = ui.theme.panel;
    panel.border = ui.theme.border;

    const root = ui.column(&.{
        ui.text("ELMZ GALLERY", 22),
        ui.muted("a runtime above its backend", 10),
        ui.spaceBefore(nav, 8),
        ui.spaceBefore(panel, 6),
        ui.spaceBefore(ui.textFmt("clicks {d}   view {s}   level {d}", .{
            m.clicks, @tagName(m.tab), m.level,
        }, 10), 8),
    });
    root.pad = 22;
    root.gap = 4;
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
    defer canvas.deinit();

    const shots = [_]Model{
        .{ .tab = .overview, .level = 4, .clicks = 3 },
        .{ .tab = .overview, .level = 8, .clicks = 9 },
        .{ .tab = .list, .selected = 2, .clicks = 14 },
        .{ .tab = .about, .clicks = 21 },
    };

    const gap: u32 = 12;
    var sheet = try software.Canvas.init(gpa, (W + gap) * shots.len + gap, H + 2 * gap);
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
