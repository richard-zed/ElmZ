//! What the debug overlay looks like, rendered headless so its layout can be
//! inspected without a window. `zig build run-overlay` -> overlay.png.
//!
//! The NUMBERS here are a sample. Inside `run` they come from a real clock and
//! a rolling window of painted frames; this file exists to show the shape of
//! the thing -- four lines, top-left, drawn over whatever the app painted --
//! and to keep it from silently becoming unreadable as the font changes.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var canvas = try software.Canvas.init(gpa, 460, 200);
    defer canvas.deinit();

    const theme: elmz.Theme = .{};
    const accent = theme.accent;
    const fg = theme.text;

    canvas.clear(theme.bg);
    // Some furniture, so the overlay is judged against content rather than
    // against a flat field. A card, a bar, a line of text.
    canvas.roundRect(.{ .x = 20, .y = 40, .w = 420, .h = 120 }, 12, .{ .solid = theme.panel }, false);
    canvas.fillRect(.{ .x = 40, .y = 70, .w = 260, .h = 10 }, elmz.Fill.hgrad(accent, theme.pressed));
    canvas.drawText(40, 96, 14, .{ .solid = fg }, "a frame, with the readout on it");

    runner.drawOverlay(&canvas, .{
        .frame_ns = 850_000,
        .build_ns = 47_000,
        .paint_ns = 803_000,
        .mean_ns = 912_000,
        .prims = 80,
        .hits = 5,
    });

    try canvas.writePng(init.io, gpa, "overlay.png");
    std.debug.print("overlay.png {d}x{d}, overlay compiled in: {s}\n", .{
        canvas.w,
        canvas.h,
        if (runner.default_overlay) "yes (debug)" else "no (release)",
    });
}
