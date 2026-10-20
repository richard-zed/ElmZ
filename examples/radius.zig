//! Corner radii: a grid of fills and outlines at increasing radius, plus one
//! rounded container with text inside it. Headless — writes radius.png.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

const Model = struct {};
const Msg = enum {};

fn update(_: *Model, _: Msg) elmz.Action(Msg) {
    return .{};
}

fn cards(ui: *elmz.Ui(Msg), filled: bool) *elmz.Element(Msg) {
    const radii = [_]f32{ 0, 3, 6, 14, 28 };
    var items: [radii.len]*elmz.Element(Msg) = undefined;
    for (radii, 0..) |rad, i| {
        const c = ui.rect(56, 56);
        c.radius = rad;
        if (filled) {
            c.bg = ui.theme.control;
        } else {
            c.border = ui.theme.accent;
        }
        items[i] = c;
    }
    const row = ui.row(&items);
    row.gap = 14;
    return row;
}

fn view(_: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const caption = ui.muted(
        "the same 1px outline follows the curve instead of four quads",
        10,
    );
    caption.wrap = true;
    const inner = ui.column(&.{
        ui.text("radius", 18),
        caption,
    });
    inner.pad = 14;
    // the card holds the paragraph to 300, which is what the paragraph used to
    // be told directly; now the container's width is the only place it can come
    // from, so the two cannot disagree
    inner.width = 300 + 2 * 14;
    inner.gap = 6;
    inner.bg = ui.theme.panel;
    inner.border = ui.theme.text_muted;
    inner.radius = 18;

    const col = ui.column(&.{
        ui.text("corner radii", 22),
        ui.spaceBefore(cards(ui, true), 4),
        ui.spaceBefore(cards(ui, false), 6),
        ui.spaceBefore(inner, 10),
    });
    col.pad = 24;
    col.gap = 4;
    col.bg = ui.theme.bg;
    return col;
}

pub fn main(init: std.process.Init) !void {
    // `start.zig` has already built the general purpose allocator (leak checking
    // included, in Debug) and the IO runtime. Constructing our own only
    // duplicated them -- this is where five copies of `std.Io.Threaded.init`
    // came from, in a program that never wanted a thread.
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, 380, 330);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
    defer frame.deinit();

    try canvas.writePng(io, gpa, "radius.png");

    var rr: usize = 0;
    for (frame.prims) |p| switch (p) {
        .rrect => rr += 1,
        else => {},
    };
    try out.print("wrote radius.png: {d} primitives, {d} rounded\n", .{ frame.prims.len, rr });
    try out.flush();
}
