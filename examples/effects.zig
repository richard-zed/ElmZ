//! Two effects that read the destination rather than the element: a cast shadow
//! and a frosted backdrop.
//!
//! Rendered through the software canvas directly, not through `Ui`, because both
//! of these want OVERLAP -- a frost has nothing to blur unless there is detail
//! under the panel it frosts, and a cast shadow has to sit partly under the thing
//! casting it. Layout here is flow-only, so the demonstration drops a level rather
//! than pretending a pair of side-by-side cards shows either effect.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");

const W = 520;
const H = 300;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var c = try software.Canvas.init(gpa, W, H);
    defer c.deinit();
    const r = c.renderer();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = W, .h = H };

    const page = elmz.Color.rgbHex(0x1e1e2e);
    r.quad(clip, .{ .solid = page }, clip);

    // -- the backdrop the frost has to work on ------------------------------
    // Hard 4px stripes: a blur over a smooth gradient is a no-op, so a demo on a
    // gradient would "work" while proving nothing.
    var x: usize = 0;
    while (x < W) : (x += 1) {
        const on = (x / 4) % 2 == 0;
        const col = if (on) elmz.Color.rgbHex(0x89b4fa) else elmz.Color.rgbHex(0x1e1e2e);
        r.quad(.{ .x = @floatFromInt(x), .y = 120, .w = 1, .h = 150 }, .{ .solid = col }, clip);
    }

    // The left half stays sharp. The right half gets a frost, so one picture holds
    // both the "before" and the "after" rather than asking anyone to remember.
    r.frost(.{ .x = 280, .y = 120, .w = 200, .h = 150 }, 0, 22, clip);
    // A translucent tint over the frosted half only: that is what makes a frost
    // read as glass instead of as a blur.
    r.quad(.{ .x = 280, .y = 120, .w = 200, .h = 150 }, .{ .solid = .{ .r = 0x31, .g = 0x32, .b = 0x44, .a = 120 } }, clip);

    // -- the shadow, over and under its own card ----------------------------
    // Same card, same distance, light from OPPOSITE sides. The shadow follows the
    // light: wide falloff and a clean edge on the lit side, long tail on the cast
    // side. An offset alone displaces the silhouette and leaves every edge with the
    // same falloff, which reads as a copy rather than as cast light.
    const dark = elmz.Color{ .r = 0x08, .g = 0x07, .b = 0x0e, .a = 200 };
    const card = elmz.Color.rgbHex(0x313244);

    const plain = elmz.Rect{ .x = 60, .y = 40, .w = 170, .h = 56 };
    r.quad(plain, .{ .solid = card }, clip);
    r.halo(plain, 10, .{ .color = dark, .blur = 24, .spread = 2, .offset = .{ 0, 10 }, .mode = .outer_glow }, clip);

    const lit = elmz.Rect{ .x = 290, .y = 40, .w = 170, .h = 56 };
    r.quad(lit, .{ .solid = card }, clip);
    r.halo(lit, 10, elmz.Halo.shadow(dark, 180, 10), clip); // clock 180: light from below

    try c.writePng(io, gpa, "effects.png");

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("effects.png  shadow: light from above (left) vs light from below (right)\n", .{});
    try w.interface.print("             frost: sharp stripes (left) vs frosted + tinted (right)\n", .{});
    try w.interface.flush();
}
