//! Every place a colour can go, taking a fill instead: backgrounds, borders
//! (rounded and square), bar fills, and text. Headless: `zig build run-paint`
//! writes paint.png.
//!
//! The point of the picture is the two border boxes on the second row. A solid
//! square border is four 1px quads, and a gradient cannot be drawn that way --
//! each quad's box is 1px on its short axis, so the ramp would restart per
//! edge. Those route through the SDF stroke instead and ramp around the whole
//! outline, which is what the top-to-bottom colour change shows.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .title = "elmz - fills",
    .size = .{ .w = 560, .h = 400 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

const W = app.size.w;
const H = app.size.h;

pub const Msg = enum {};
pub const Model = struct {};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    _ = m;
    _ = msg;
    return .{};
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    _ = m;
    const th = ui.theme;
    const pink = elmz.Color.rgbHex(0xf5c2e7);
    const green = elmz.Color.rgbHex(0xa6e3a1);

    const title = ui.text(.{ .label = "fills", .size = 22 });
    title.fg_grad = elmz.Fill.hgrad(th.accent, pink);

    // -- backgrounds -------------------------------------------------------
    const vert = ui.rect(.{ .width = 160, .height = 90 });
    vert.bg_grad = elmz.Fill.vgrad(th.accent, th.bg);
    vert.radius = 10;

    const horz = ui.rect(.{ .width = 160, .height = 90 });
    horz.bg_grad = elmz.Fill.hgrad(th.bg, pink);
    horz.radius = 10;

    const rad = ui.rect(.{ .width = 160, .height = 90 });
    rad.bg_grad = elmz.Fill.radialFill(th.accent, th.bg);
    rad.radius = 10;

    const bg_row = ui.row(.{ .children = &.{ vert, horz, rad } });
    bg_row.gap = 12;

    // -- borders -----------------------------------------------------------
    const square = ui.rect(.{ .width = 160, .height = 72 });
    square.border_grad = elmz.Fill.vgrad(th.accent, green);

    const round = ui.rect(.{ .width = 160, .height = 72 });
    round.radius = 16;
    round.border_grad = elmz.Fill.hgrad(pink, th.accent);

    const tri = ui.rect(.{ .width = 160, .height = 72 });
    tri.radius = 16;
    tri.bg_grad = .{ .linear = .{ .stops = elmz.Stops.three(th.accent, pink, green) } };

    const border_row = ui.row(.{ .children = &.{ square, round, tri } });
    border_row.gap = 12;

    // -- text and a bar ----------------------------------------------------
    const grad_text = ui.text(.{ .label = "gradient text runs", .size = 26 });
    grad_text.fg_grad = elmz.Fill.hgrad(th.accent, pink);

    const bar = ui.bar(.{ .value = 0.65 });
    bar.width = 504;
    bar.height = 14;
    bar.fg_grad = elmz.Fill.hgrad(th.accent, green);

    const note = ui.text(.{ .label = "backgrounds, borders (square and rounded) and text all take a Fill", .size = 12, .tone = .muted });

    const root = ui.column(.{ .children = &.{
        title,
        ui.spaceBefore(bg_row, 10),
        ui.spaceBefore(border_row, 14),
        ui.spaceBefore(grad_text, 16),
        ui.spaceBefore(bar, 10),
        ui.spaceBefore(note, 12),
    } });
    root.pad = 20;
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

    var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
    defer frame.deinit();

    try canvas.writePng(io, gpa, "paint.png");
    var grads: usize = 0;
    for (frame.prims) |p| switch (p) {
        .quad => |q| {
            if (!q.fill.isSolid()) grads += 1;
        },
        .rrect => |q| {
            if (!q.fill.isSolid()) grads += 1;
        },
        .text => |t| {
            if (!t.fill.isSolid()) grads += 1;
        },
    };
    try out.print("wrote paint.png: {d} primitives, {d} with gradient fills\n", .{ frame.prims.len, grads });
    try out.flush();
}
