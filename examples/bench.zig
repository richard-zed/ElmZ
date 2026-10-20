//! Where a frame's time actually goes, by primitive count.
//!
//! Three questions, one harness:
//!   1. how does build (view + layout + hit list) scale with prim count,
//!   2. how does rasterisation scale with the same,
//!   3. what does a hovering pointer cost on top of the first,
//!   4. what each fill VARIANT costs per pixel (paint is area-bound, so this
//!      is the only question that can move the frame time),
//!   5. whether the halo crossover at 10px is priced right: distance field
//!      per pixel against one bake plus a blit.
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

/// One full-canvas fill, repeated. Paint is the expensive half of a frame and
/// it is area-bound, so the useful unit is nanoseconds per pixel per VARIANT --
/// a solid quad and a diagonal ramp are the same work at the prim level and
/// nothing alike at the pixel level.
fn measureFill(io: std.Io, c: *software.Canvas, fill: elmz.Fill, iters: usize) u64 {
    const rect = elmz.Rect{ .x = 0, .y = 0, .w = @floatFromInt(c.w), .h = @floatFromInt(c.h) };
    c.fillRectClip(rect, fill, rect); // warm: first touch costs page faults
    const t0 = ns(io);
    for (0..iters) |_| c.fillRectClip(rect, fill, rect);
    const t1 = ns(io);
    return @intCast(@divTrunc(t1 - t0, @as(i128, @intCast(iters))));
}

/// A halo is either a distance field evaluated per pixel or one baked stencil
/// blitted. `cold` is the bake (cache miss, full silhouette built); `hot` is
/// the blit. If `hot_baked` is not clearly cheaper than `sdf` at a given blur,
/// the crossover is on the wrong side of it.
const HaloCost = struct { cold: u64, hot: u64, stencils: usize };

fn measureHalo(io: std.Io, gpa: std.mem.Allocator, h: elmz.Halo, w: f32, ht: f32, iters: usize) !HaloCost {
    const cw: u32 = @intFromFloat(w + 120);
    const ch: u32 = @intFromFloat(ht + 120);
    var c = try software.Canvas.init(gpa, cw, ch);
    defer c.deinit();
    const rect = elmz.Rect{ .x = 60, .y = 60, .w = w, .h = ht };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = @floatFromInt(cw), .h = @floatFromInt(ch) };
    const t0 = ns(io);
    c.halo(rect, 8, h, clip);
    const t1 = ns(io);
    for (0..iters) |_| c.halo(rect, 8, h, clip);
    const t2 = ns(io);
    return .{
        .cold = @intCast(t1 - t0),
        .hot = @intCast(@divTrunc(t2 - t1, @as(i128, @intCast(iters)))),
        .stencils = c.masks.items.len,
    };
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

    // -- fill variants -----------------------------------------------------
    // Same rect, same area, same call: only the Fill changes. A solid quad is
    // a hoisted colour loop; a vertical ramp is one colour per scanline and
    // keeps the row fill; anything with a horizontal component cannot hoist
    // and pays per pixel.
    {
        var fc = try software.Canvas.init(gpa, 640, 480);
        defer fc.deinit();
        const a = elmz.Color{ .r = 0x1e, .g = 0x1e, .b = 0x2e, .a = 255 };
        const b = elmz.Color{ .r = 0xf3, .g = 0xc0, .b = 0xe5, .a = 255 };
        const area = @as(f64, @floatFromInt(640 * 480));
        const iters: usize = 20;

        const cases = [_]struct { name: []const u8, fill: elmz.Fill }{
            .{ .name = "solid", .fill = .{ .solid = a } },
            .{ .name = "vertical", .fill = elmz.Fill.vgrad(a, b) },
            .{ .name = "horizontal", .fill = elmz.Fill.hgrad(a, b) },
            .{ .name = "diagonal 45", .fill = elmz.Fill.angled(45, a, b) },
            .{ .name = "diagonal 115", .fill = elmz.Fill.angled(115, a, b) },
            .{ .name = "radial", .fill = elmz.Fill.radialFill(a, b) },
        };
        try out.print("\n  640x480 full-canvas fill, {d} passes each\n", .{iters});
        try out.print("  variant        ms/pass   ns/px   vs solid\n", .{});
        var solid_ns: f64 = 0;
        for (cases, 0..) |cs, i| {
            const t = measureFill(io, &fc, cs.fill, iters);
            const nspx = @as(f64, @floatFromInt(t)) / area;
            if (i == 0) solid_ns = nspx;
            const ratio = if (solid_ns > 0) nspx / solid_ns else 0;
            try out.print("  {s:<12} {d:>8.3}  {d:>5.2}   {d:>5.2}x\n", .{
                cs.name,
                @as(f64, @floatFromInt(t)) / 1e6,
                nspx,
                ratio,
            });
        }
    }

    // -- halo: distance field or baked stencil -----------------------------
    // The crossover is a constant in the renderer, so it needs a number under
    // it. Below the crossover the field wins because a bake is an allocation
    // and a full second silhouette; above it the field is quadratic in blur
    // while a blit is flat.
    {
        try out.print("\n  halo, 200x120 at radius 8    (cold = bake, hot = blit)\n", .{});
        try out.print("  blur    sdf hot   baked cold   baked hot\n", .{});
        const col = elmz.Color{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 120 };
        for ([_]f32{ 4, 8, 10, 16, 24, 40 }) |blur| {
            const base = elmz.Halo{ .color = col, .blur = blur, .mode = .glow };
            const s = try measureHalo(io, gpa, .{ .color = base.color, .blur = base.blur, .mode = base.mode, .quality = .sdf }, 200, 120, 20);
            const bk = try measureHalo(io, gpa, .{ .color = base.color, .blur = base.blur, .mode = base.mode, .quality = .baked }, 200, 120, 20);
            try out.print("  {d:>4.0}   {d:>7.1}us   {d:>9.1}us  {d:>9.1}us\n", .{
                blur,
                @as(f64, @floatFromInt(s.hot)) / 1000,
                @as(f64, @floatFromInt(bk.cold)) / 1000,
                @as(f64, @floatFromInt(bk.hot)) / 1000,
            });
        }
    }

    // -- halo: does slicing hold up as the silhouette grows? ----------------
    // A full bake scales with AREA; a sliced one scales with the same area for
    // the blit but only a fixed square for the bake. This sweep is what decides
    // whether the distance field should stay the default anywhere above the
    // crossover.
    {
        try out.print("\n  halo, blur 24, radius 8, by silhouette   (stencils = entries kept)\n", .{});
        try out.print("  size          sdf hot   baked cold   baked hot  stencils\n", .{});
        const col = elmz.Color{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 120 };
        const sizes = [_][2]f32{ .{ 200, 120 }, .{ 640, 120 }, .{ 1280, 200 }, .{ 1440, 300 } };
        for (sizes) |sz| {
            const base = elmz.Halo{ .color = col, .blur = 24, .mode = .glow };
            const s = try measureHalo(io, gpa, .{ .color = base.color, .blur = base.blur, .mode = base.mode, .quality = .sdf }, sz[0], sz[1], 10);
            const bk = try measureHalo(io, gpa, .{ .color = base.color, .blur = base.blur, .mode = base.mode, .quality = .baked }, sz[0], sz[1], 10);
            try out.print("  {d:>4.0}x{d:<4.0}   {d:>7.1}us   {d:>9.1}us  {d:>9.1}us  {d:>6}\n", .{
                sz[0],
                sz[1],
                @as(f64, @floatFromInt(s.hot)) / 1000,
                @as(f64, @floatFromInt(bk.cold)) / 1000,
                @as(f64, @floatFromInt(bk.hot)) / 1000,
                bk.stencils,
            });
        }
    }
    try out.flush();
}
