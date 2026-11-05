//! Filling outlines, and what the fill rule decides when two contours overlap. Headless:
//! `zig build run-path` writes path.png.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");

const W = 520;
const H = 440;

const tile = 160;
const gap = 40;

/// Two squares, one path: outer 0..100, inner inset 30, so a hole is a 40x40 square in the
/// middle. `inner_reversed` is the whole point.
fn squares(comptime inner_reversed: bool) elmz.Path {
    const pts: [8][2]f32 = if (inner_reversed)
        .{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 0, 100 }, .{ 30, 30 }, .{ 30, 70 }, .{ 70, 70 }, .{ 70, 30 } }
    else
        .{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 0, 100 }, .{ 30, 30 }, .{ 70, 30 }, .{ 70, 70 }, .{ 30, 70 } };
    return .{
        .ops = &[_]elmz.PathOp{ .move, .line, .line, .line, .close, .move, .line, .line, .line, .close },
        .points = &pts,
    };
}

/// The same-winding squares with the rule flipped. Identical points to the top-right tile,
/// so anything that differs on screen is the rule's doing.
fn squaresRule(comptime rule: elmz.FillRule) elmz.Path {
    var p = squares(false);
    p.rule = rule;
    return p;
}

/// Four quads, no corners: the control points sit on the box corners so the sides bow
/// outward into something round.
fn blob() elmz.Path {
    return .{
        .ops = &[_]elmz.PathOp{ .move, .quad, .quad, .quad, .quad, .close },
        .points = &[_][2]f32{
            .{ 100, 50 },
            .{ 100, 100 },
            .{ 50, 100 },
            .{ 0, 100 },
            .{ 0, 50 },
            .{ 0, 0 },
            .{ 50, 0 },
            .{ 100, 0 },
            .{ 100, 50 },
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var c = try software.Canvas.init(gpa, W, H);
    // By NAME, the way an app names a face in its theme: whichever face this
    // machine has, or none. With no fonts installed every example still runs and
    // the text falls back to the built-in bitmap face.
    const c_bytes = software.loadFontByName(gpa, io, "DejaVu Sans", &.{}) catch null;
    defer if (c_bytes) |fb| gpa.free(fb);
    if (c_bytes) |fb| c.setFont(fb);
    defer c.deinit();
    const r = c.renderer();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = W, .h = H };

    const bg = elmz.Color.rgbHex(0x1e1e2e);
    const panel = elmz.Color.rgbHex(0x313244);
    const accent = elmz.Color.rgbHex(0x89b4fa);
    const text = elmz.Color.rgbHex(0xa6adc8);
    r.quad(clip, .{ .solid = bg }, clip);

    const Tile = struct { x: f32, y: f32, p: elmz.Path, label: []const u8 };
    const tiles = [_]Tile{
        .{ .x = gap, .y = gap, .p = squares(true), .label = "nonzero, reversed inner" },
        .{ .x = gap + tile + gap, .y = gap, .p = squares(false), .label = "nonzero, same winding" },
        .{ .x = gap, .y = gap * 2 + tile, .p = squaresRule(.evenodd), .label = "evenodd, same winding" },
        .{ .x = gap + tile + gap, .y = gap * 2 + tile, .p = blob(), .label = "curves: four quads" },
    };

    for (tiles) |t| {
        r.roundedRect(.{ .x = t.x, .y = t.y, .w = tile, .h = tile }, 12, .{ .solid = panel }, false, clip);
        r.roundedRect(.{ .x = t.x, .y = t.y, .w = tile, .h = tile }, 12, .{ .solid = elmz.Color.rgbHex(0x585b70) }, true, clip);
        // Centred: the shapes are authored in a 100x100 box.
        r.path(t.x + 30, t.y + 30, t.p, .{ .solid = accent }, clip);
        r.text(t.x, t.y + tile + 22, 13, .{ .solid = text }, t.label, clip);
    }

    try c.writePng(io, gpa, "path.png");

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("path.png  same geometry, rule decides:\n", .{});
    try w.interface.print("  top    nonzero: reversed inner contour = hole, same winding = solid\n", .{});
    try w.interface.print("  bottom evenodd: same winding still cuts a hole; curves flatten, not corners\n", .{});
    try w.interface.flush();
}
