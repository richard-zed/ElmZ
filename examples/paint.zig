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

    const title = ui.text(.{ .label = "fills", .size = 22, .style = .{ .fg_grad = elmz.Fill.hgrad(th.accent, pink) } });

    // -- backgrounds -------------------------------------------------------
    const vert = ui.rect(.{ .width = 160, .height = 90, .style = .{ .bg_grad = elmz.Fill.vgrad(th.accent, th.bg), .radius = 10 } });

    const horz = ui.rect(.{ .width = 160, .height = 90, .style = .{ .bg_grad = elmz.Fill.hgrad(th.bg, pink), .radius = 10 } });

    const rad = ui.rect(.{ .width = 160, .height = 90, .style = .{ .bg_grad = elmz.Fill.radialFill(th.accent, th.bg), .radius = 10 } });

    const bg_row = ui.row(.{ .children = &.{ vert, horz, rad }, .gap = 12 });

    // -- borders -----------------------------------------------------------
    const square = ui.rect(.{ .width = 160, .height = 72, .style = .{ .border_grad = elmz.Fill.vgrad(th.accent, green) } });

    const round = ui.rect(.{ .width = 160, .height = 72, .style = .{ .radius = 16, .border_grad = elmz.Fill.hgrad(pink, th.accent) } });

    const tri = ui.rect(.{ .width = 160, .height = 72, .style = .{ .radius = 16, .bg_grad = .{ .linear = .{ .stops = elmz.Stops.three(th.accent, pink, green) } } } });

    const border_row = ui.row(.{ .children = &.{ square, round, tri }, .gap = 12 });

    // -- text and a bar ----------------------------------------------------
    const grad_text = ui.text(.{ .label = "gradient text runs", .size = 26, .style = .{ .fg_grad = elmz.Fill.hgrad(th.accent, pink) } });

    const bar = ui.bar(.{ .value = 0.65, .width = 504, .height = 14, .style = .{ .fg_grad = elmz.Fill.hgrad(th.accent, green) } });

    const note = ui.text(.{ .label = "backgrounds, borders (square and rounded) and text all take a Fill", .size = 12, .tone = .muted });

    bg_row.margin_top = 10;
    border_row.margin_top = 14;
    grad_text.margin_top = 16;
    bar.margin_top = 10;
    note.margin_top = 12;
    const root = ui.column(.{ .children = &.{
        title,
        bg_row,
        border_row,
        grad_text,
        bar,
        note,
    }, .style = .{ .pad = 20 } });
    return root;
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

    var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
    defer frame.deinit();

    try canvas.writePng(io, gpa, "paint.png");
    var grads: usize = 0;
    for (frame.prims) |p| switch (p) {
        .quad => |q| {
            if (!q.fill.isSolid()) grads += 1;
        },
        .halo => {},
        .frost => {},
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
