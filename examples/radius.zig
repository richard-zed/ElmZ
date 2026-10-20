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
        const c = ui.rect(.{ .width = 56, .height = 56, .style = .{
            .radius = rad,
            .bg = if (filled) ui.theme.control else null,
            .border = if (filled) null else ui.theme.accent,
        } });
        items[i] = c;
    }
    const row = ui.row(.{ .children = &items, .gap = 14 });
    return row;
}

fn view(_: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const caption = ui.text(.{ .label = "the same 1px outline follows the curve instead of four quads", .size = 10, .tone = .muted, .wrap = true });
    // the card holds the paragraph to 300, which is what the paragraph used to
    // be told directly; now the container's width is the only place it can come
    // from, so the two cannot disagree
    const inner = ui.column(.{ .children = &.{
        ui.text(.{ .label = "radius", .size = 18 }),
        caption,
    }, .width = 300 + 2 * 14, .gap = 6, .style = .{ .pad = 14, .bg = ui.theme.panel, .border = ui.theme.text_muted, .radius = 18 } });

    const col = ui.column(.{ .children = &.{
        ui.text(.{ .label = "corner radii", .size = 22 }),
        ui.spaceBefore(cards(ui, true), 4),
        ui.spaceBefore(cards(ui, false), 6),
        ui.spaceBefore(inner, 10),
    }, .gap = 4, .style = .{ .pad = 24, .bg = ui.theme.bg } });
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
