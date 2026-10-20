//! Where a frame's time actually goes, by primitive count.
//!
//! Three questions, one harness:
//!   1. how does build (view + layout + hit list) scale with prim count,
//!   2. how does rasterisation scale with the same,
//!   3. what does a hovering pointer cost on top of the first.
//!
//! Headless on purpose: the numbers are the output. `zig build run-bench`.
//! No PNG -- a picture of a benchmark is a bar chart, and this prints one.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");

const W: u32 = 520;
/// Tall enough that 400 rows are on-canvas. Anything the clip prunes would
/// shrink the prim count and quietly measure a smaller frame than it claims.
const H: u32 = 7200;

pub const Msg = enum { inc };

pub const Model = struct {
    rows: usize = 0,
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .inc => m.rows +%= 1,
    }
    return .{};
}

const Elem = elmz.Element(Msg);

/// One row = 5 prims (row fill, swatch, label, button fill, button label) and
/// one hit region, so `rows` is a dial on prim count that stays realistic
/// rather than 2000 stacked rectangles.
pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *Elem {
    var buf: [512]*Elem = undefined;
    const n = @min(m.rows, buf.len);
    for (0..n) |i| {
        buf[i] = ui.row(.{ .children = &.{
            ui.rect(.{ .width = 6, .height = 12 }),
            ui.text(.{ .label = "row", .size = 10 }),
            ui.button(.{ .label = "go", .msg = .inc }),
        }, .gap = 4, .style = .{ .pad = 2, .bg = ui.theme.panel } });
    }
    return ui.column(.{ .children = buf[0..n] });
}

const Row = struct {
    rows: usize,
    prims: usize,
    hits: usize,
    build_ns: u64,
    paint_ns: u64,
};

fn ns(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn measure(
    io: std.Io,
    rt: *elmz.Runtime(Model, Msg),
    canvas: *software.Canvas,
    rows: usize,
    iters: usize,
    hover: ?[2]f32,
) !Row {
    rt.state.rows = rows;
    rt.pointer.pos = hover;

    // One discarded iteration: the first frame pays for page faults on a fresh
    // arena and would otherwise be charged to whatever row happened to be first.
    {
        var f = try rt.frame(.{ .w = @floatFromInt(canvas.w), .h = @floatFromInt(canvas.h) }, canvas.renderer());
        f.deinit();
    }

    var out: Row = .{ .rows = rows, .prims = 0, .hits = 0, .build_ns = 0, .paint_ns = 0 };
    for (0..iters) |_| {
        const t0 = ns(io);
        var f = try rt.frame(.{ .w = @floatFromInt(canvas.w), .h = @floatFromInt(canvas.h) }, canvas.renderer());
        const t1 = ns(io);
        canvas.clear(rt.ui.theme.bg);
        canvas.paintFrame(f.prims);
        const t2 = ns(io);
        out.prims = f.prims.len;
        out.hits = f.hits.len;
        out.build_ns += @intCast(t1 - t0);
        out.paint_ns += @intCast(t2 - t1);
        f.deinit();
    }
    out.build_ns /= @intCast(iters);
    out.paint_ns /= @intCast(iters);
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    try out.print("canvas {d}x{d}\n\n", .{ W, H });
    try out.print("  rows  prims  hits   build ms   paint ms\n", .{});
    for ([_]usize{ 40, 100, 400 }) |rows| {
        const iters: usize = if (rows > 200) 5 else 20;
        const r = try measure(io, &rt, &canvas, rows, iters, null);
        try out.print("  {d:>4}  {d:>5}  {d:>4}   {d:>8.3}   {d:>8.3}\n", .{
            r.rows,
            r.prims,
            r.hits,
            @as(f64, @floatFromInt(r.build_ns)) / 1e6,
            @as(f64, @floatFromInt(r.paint_ns)) / 1e6,
        });
    }

    // Hover: same geometry, pointer parked over the button column. The delta is
    // the second traversal the hit list forces on hovered frames.
    try out.print("\n  pointer over a button (hover scan)\n", .{});
    try out.print("  rows  build ms  no hover   build ms  hover    delta\n", .{});
    for ([_]usize{ 40, 100, 400 }) |rows| {
        const iters: usize = if (rows > 200) 5 else 20;
        const cold = try measure(io, &rt, &canvas, rows, iters, null);
        const hot = try measure(io, &rt, &canvas, rows, iters, .{ W - 40, 40 });
        try out.print("  {d:>4}   {d:>9.3}   {d:>9.3}   {d:>7.3}\n", .{
            rows,
            @as(f64, @floatFromInt(cold.build_ns)) / 1e6,
            @as(f64, @floatFromInt(hot.build_ns)) / 1e6,
            (@as(f64, @floatFromInt(hot.build_ns)) - @as(f64, @floatFromInt(cold.build_ns))) / 1e6,
        });
    }

    // A full repaint is the unit an unearned `dirty` spends. Priced here so the
    // pointer_up question can be answered in milliseconds instead of opinion.
    const full = try measure(io, &rt, &canvas, 100, 20, null);
    try out.print("\n  one full frame at {d} prims = {d:.3} ms ({d:.3} build + {d:.3} paint)\n", .{
        full.prims,
        @as(f64, @floatFromInt(full.build_ns + full.paint_ns)) / 1e6,
        @as(f64, @floatFromInt(full.build_ns)) / 1e6,
        @as(f64, @floatFromInt(full.paint_ns)) / 1e6,
    });
    // The realistic regime: a window-sized canvas, few prims. Paint is
    // area-bound, so this -- not the tall canvas -- is what a user actually
    // pays per repaint, and it prices an unearned `dirty` honestly.
    var win = try software.Canvas.init(gpa, 480, 400);
    defer win.deinit();
    const wf = try measure(io, &rt, &win, 20, 50, null);
    try out.print("  window 480x400, {d} prims = {d:.3} ms ({d:.3} build + {d:.3} paint)\n", .{
        wf.prims,
        @as(f64, @floatFromInt(wf.build_ns + wf.paint_ns)) / 1e6,
        @as(f64, @floatFromInt(wf.build_ns)) / 1e6,
        @as(f64, @floatFromInt(wf.paint_ns)) / 1e6,
    });
    const pixels = @as(f64, @floatFromInt(480 * 400));
    try out.print("  paint cost = {d:.1} ns/pixel\n", .{
        @as(f64, @floatFromInt(wf.paint_ns)) / pixels,
    });
    try out.flush();
}
