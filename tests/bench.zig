//! Where a frame's time actually goes, by primitive count. Three questions, one harness: 1.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");

const W: u32 = 520;
/// Tall enough that 400 rows are on-canvas. Anything the clip prunes would shrink the prim
/// count and quietly measure a smaller frame than it claims.
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

/// A tree of exactly one widget type, repeated, so build cost per widget can be
/// divided out. The row benchmark mixes five primitive kinds, which is fine for
/// a frame total and useless for "what does a button cost".
pub const Widget = enum { text, button, row, checkbox };
pub const WModel = struct {
    kind: Widget = .text,
    n: usize = 1,
};

pub fn wview(m: *WModel, ui: *elmz.Ui(Msg)) *Elem {
    var buf: [256]*Elem = undefined;
    const n = @min(m.n, buf.len);
    for (0..n) |i| {
        buf[i] = switch (m.kind) {
            .text => ui.text(.{ .label = "label", .size = 10 }),
            .button => ui.button(.{ .label = "go", .msg = .inc }),
            .row => ui.row(.{ .children = &.{
                ui.rect(.{ .width = 6, .height = 12 }),
                ui.text(.{ .label = "row", .size = 10 }),
                ui.button(.{ .label = "go", .msg = .inc }),
            }, .gap = 4, .style = .{ .pad = 2, .bg = elmz.solid(ui.theme.panel) } }),
            .checkbox => ui.checkbox(.{ .key = i, .label = "pick", .checked = false, .msg = .inc }),
        };
    }
    return ui.column(.{ .children = buf[0..n] });
}

pub fn wupdate(m: *WModel, msg: Msg) elmz.Action(Msg) {
    _ = msg;
    m.n +%= 0;
    return .{};
}

/// One row = 5 prims (row fill, swatch, label, button fill, button label) and one hit
/// region.
pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *Elem {
    var buf: [512]*Elem = undefined;
    const n = @min(m.rows, buf.len);
    for (0..n) |i| {
        buf[i] = ui.row(.{ .children = &.{
            ui.rect(.{ .width = 6, .height = 12 }),
            ui.text(.{ .label = "row", .size = 10 }),
            ui.button(.{ .label = "go", .msg = .inc }),
        }, .gap = 4, .style = .{ .pad = 2, .bg = elmz.solid(ui.theme.panel) } });
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

/// Best-of-N with the spread of the samples. One sample cannot be told apart
/// from the noise floor: filling the same solid rect twice on an idle machine
/// has differed by 12%, which is wider than most wins worth keeping.
const Sample = struct { best: u64, worst: u64 };

fn repeatFill(io: std.Io, c: *software.Canvas, fill: elmz.Fill, iters: usize) Sample {
    var best: u64 = std.math.maxInt(u64);
    var worst: u64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const t = measureFill(io, c, fill, iters);
        if (t < best) best = t;
        if (t > worst) worst = t;
    }
    return .{ .best = best, .worst = worst };
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

/// One full-canvas fill, repeated.
fn measureFill(io: std.Io, c: *software.Canvas, fill: elmz.Fill, iters: usize) u64 {
    const rect = elmz.Rect{ .x = 0, .y = 0, .w = @floatFromInt(c.w), .h = @floatFromInt(c.h) };
    c.fillRectClip(rect, fill, rect); // warm: first touch costs page faults
    const t0 = ns(io);
    for (0..iters) |_| c.fillRectClip(rect, fill, rect);
    const t1 = ns(io);
    return @intCast(@divTrunc(t1 - t0, @as(i128, @intCast(iters))));
}

/// A halo is either a distance field evaluated per pixel or one baked stencil blitted.
const HaloCost = struct { cold: u64, hot: u64, stencils: usize };

/// One frame of `k` distinct silhouettes, repeated.
const Stress = struct { ns: i128, bakes: usize, stencils: usize };

fn measureStress(io: std.Io, gpa: std.mem.Allocator, quality: elmz.Halo.Quality, k: usize, iters: usize) !Stress {
    var c = try software.Canvas.init(gpa, 480, 420);
    defer c.deinit();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 480, .h = 420 };
    const col = elmz.Color{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 120 };

    const draw = struct {
        fn go(cv: *software.Canvas, cl: elmz.Rect, cc: elmz.Color, q: elmz.Halo.Quality, count: usize) void {
            for (0..count) |i| {
                const cx: f32 = @floatFromInt(i % 4);
                const cy: f32 = @floatFromInt(i / 4);
                const rect = elmz.Rect{
                    .x = 10 + cx * 118,
                    .y = 10 + cy * 100,
                    .w = 100,
                    .h = 60,
                };
                cv.halo(rect, 2 + @as(f32, @floatFromInt(i)), .{
                    .color = cc,
                    .blur = 24,
                    .mode = .glow,
                    .quality = q,
                }, cl);
            }
        }
    };

    draw.go(&c, clip, col, quality, k); // one warm frame, so the first bake is not billed
    c.bakes = 0;
    const t0 = ns(io);
    for (0..iters) |_| draw.go(&c, clip, col, quality, k);
    const t1 = ns(io);
    return .{
        .ns = @divTrunc(t1 - t0, @as(i128, @intCast(iters))),
        .bakes = c.bakes,
        .stencils = c.masks.items.len,
    };
}

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
    // By NAME, the way an app names a face in its theme: whichever face this
    // machine has, or none. With no fonts installed every example still runs and
    // the text falls back to the built-in bitmap face.
    const win_bytes = software.loadFontByName(gpa, init.io, "DejaVu Sans", &.{}) catch null;
    defer if (win_bytes) |fb| gpa.free(fb);
    if (win_bytes) |fb| win.setFont(fb);
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
        // By NAME, the way an app names a face in its theme: whichever face this
        // machine has, or none. With no fonts installed every example still runs and
        // the text falls back to the built-in bitmap face.
        const fc_bytes = software.loadFontByName(gpa, init.io, "DejaVu Sans", &.{}) catch null;
        defer if (fc_bytes) |fb| gpa.free(fb);
        if (fc_bytes) |fb| fc.setFont(fb);
        defer fc.deinit();
        const a = elmz.Color{ .r = 0x1e, .g = 0x1e, .b = 0x2e, .a = 255 };
        const b = elmz.Color{ .r = 0xf3, .g = 0xc0, .b = 0xe5, .a = 255 };
        const area = @as(f64, @floatFromInt(640 * 480));
        const iters: usize = 20;

        const cases = [_]struct { name: []const u8, fill: elmz.Fill }{
            .{ .name = "solid", .fill = .{ .solid = a } },
            .{ .name = "vertical", .fill = elmz.Fill.vgrad(a, b) },
            .{ .name = "horizontal", .fill = elmz.Fill.hgrad(a, b) },
            .{ .name = "diagonal 135", .fill = elmz.Fill.angled(135, a, b) },
            .{ .name = "diagonal 205", .fill = elmz.Fill.angled(205, a, b) },
            .{ .name = "radial", .fill = elmz.Fill.radialFill(a, b) },
            // Leaves the corners outside the last stop, which is the split fast
            // path. The covering shape above never reaches it, and was for a long
            // time the only radial measured.
            .{ .name = "radial split", .fill = elmz.Fill{ .radial = .{
                .radius = 0.28,
                .stops = elmz.Stops.two(a, b),
            } } },
        };
        try out.print("\n  640x480 full-canvas fill, {d} passes x5, best of 5\n", .{iters});
        try out.print("  variant        ms/pass   ns/px   vs solid   spread\n", .{});
        var solid_ns: f64 = 0;
        for (cases, 0..) |cs, i| {
            const sm = repeatFill(io, &fc, cs.fill, iters);
            const t = sm.best;
            const nspx = @as(f64, @floatFromInt(t)) / area;
            if (i == 0) solid_ns = nspx;
            const ratio = if (solid_ns > 0) nspx / solid_ns else 0;
            const spread = if (sm.best > 0)
                100.0 * @as(f64, @floatFromInt(sm.worst - sm.best)) / @as(f64, @floatFromInt(sm.best))
            else
                0;
            try out.print("  {s:<12} {d:>8.3}  {d:>5.2}   {d:>5.2}x   {d:>4.1}%\n", .{
                cs.name,
                @as(f64, @floatFromInt(t)) / 1e6,
                nspx,
                ratio,
                spread,
            });
        }
    }

    // -- widgets: build and paint split, per widget type -------------------
    // The row table's 5-prim row hides this. Here one widget type is repeated
    // 64 times so the per-widget share can be read directly.
    {
        var wrt = elmz.Runtime(WModel, Msg).init(gpa, .{}, wupdate, wview);
        defer wrt.deinit();

        const n: usize = 64;
        try out.print("\n  widgets, {d} repeated, {d}x{d}\n", .{ n, W, H });
        try out.print("  kind      build ms   paint ms   build us/each   paint us/each\n", .{});
        for ([_]Widget{ .text, .button, .row, .checkbox }) |kind| {
            wrt.state.kind = kind;
            wrt.state.n = n;
            wrt.pointer.pos = null;

            // discarded warm-up frame, same reasoning as measure()
            {
                var f = try wrt.frame(.{ .w = @floatFromInt(canvas.w), .h = @floatFromInt(canvas.h) }, canvas.renderer());
                f.deinit();
            }

            var bbest: u64 = std.math.maxInt(u64);
            var pbest: u64 = std.math.maxInt(u64);
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                const t0 = ns(io);
                var f = try wrt.frame(.{ .w = @floatFromInt(canvas.w), .h = @floatFromInt(canvas.h) }, canvas.renderer());
                const t1 = ns(io);
                canvas.clear(wrt.ui.theme.bg);
                canvas.paintFrame(f.prims);
                const t2 = ns(io);
                f.deinit();
                const b: u64 = @intCast(t1 - t0);
                const p: u64 = @intCast(t2 - t1);
                if (b < bbest) bbest = b;
                if (p < pbest) pbest = p;
            }
            try out.print("  {s:<8} {d:>8.3}  {d:>8.3}   {d:>12.2}   {d:>13.2}\n", .{
                @tagName(kind),
                @as(f64, @floatFromInt(bbest)) / 1e6,
                @as(f64, @floatFromInt(pbest)) / 1e6,
                @as(f64, @floatFromInt(bbest)) / 1e3 / @as(f64, @floatFromInt(n)),
                @as(f64, @floatFromInt(pbest)) / 1e3 / @as(f64, @floatFromInt(n)),
            });
        }
    }

    // -- glyphs: the cost the row benchmark only ever aggregates -----------
    // Every row draw above includes text, but mixed with fills, buttons and hit
    // testing, so no line here isolates a glyph. Raster cost scales with the
    // SQUARE of the point size, which is the one curve worth seeing directly.
    {
        const ink = elmz.Fill{ .solid = .{ .r = 0xf0, .g = 0xf0, .b = 0xf0, .a = 255 } };
        const clip = elmz.Rect{ .x = 0, .y = 0, .w = @floatFromInt(canvas.w), .h = @floatFromInt(canvas.h) };
        const latin = "The quick brown fox jumps over the lazy dog";
        const cjk = "\u{4e2d}\u{6587}\u{5b57}\u{4f53}\u{6e2c}\u{8a66}\u{6a19}\u{6e96}";

        try out.print("\n  glyphs, {d}-char latin line, {s}\n", .{ latin.len, if (canvas.font.available()) "real outlines" else "builtin bitmap" });
        try out.print("  size    us/draw   ns/glyph   em-px\n", .{});
        for ([_]f32{ 10, 16, 32, 64, 144 }) |sz| {
            var best: u64 = std.math.maxInt(u64);
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                canvas.drawTextClip(4, 4, sz, ink, latin, clip); // warm
                const t0 = ns(io);
                canvas.drawTextClip(4, 4, sz, ink, latin, clip);
                const t1 = ns(io);
                const d: u64 = @intCast(t1 - t0);
                if (d < best) best = d;
            }
            const per = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(latin.len));
            try out.print("  {d:>4.0}  {d:>8.1}   {d:>8.1}   {d:>5.1}\n", .{
                sz,
                @as(f64, @floatFromInt(best)) / 1e3,
                per,
                sz,
            });
        }

        // CJK: the worst case for the outline path, since CFF charstrings run
        // longer and the flattener buffer is sized off them.
        try out.print("\n  glyphs, {d}-char CJK line, {s}\n", .{ cjk.len, if (canvas.font.available()) "real outlines" else "builtin bitmap" });
        try out.print("  size    us/draw   ns/glyph\n", .{});
        for ([_]f32{ 16, 32, 64, 144 }) |sz| {
            var best: u64 = std.math.maxInt(u64);
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                canvas.drawTextClip(4, 4, sz, ink, cjk, clip);
                const t0 = ns(io);
                canvas.drawTextClip(4, 4, sz, ink, cjk, clip);
                const t1 = ns(io);
                const d: u64 = @intCast(t1 - t0);
                if (d < best) best = d;
            }
            try out.print("  {d:>4.0}  {d:>8.1}   {d:>8.1}\n", .{
                sz,
                @as(f64, @floatFromInt(best)) / 1e3,
                @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(cjk.len)),
            });
        }
    }

    // -- halo: distance field or baked stencil -----------------------------
    // The renderer bakes by default, so this table is the standing argument for
    // that choice: the field against one bake plus a blit, across the whole
    // blur range rather than either side of a threshold.
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
    // the blit but only a fixed square for the bake. This sweep is what showed
    // that the field is never the cheaper default.
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

    // -- halo: cache pressure, the last case that could favour the field ------
    // Eight entries. A cyclic redraw of more distinct silhouettes than that
    // misses every time, so `bakes/frame` should equal `shapes` from 9 up. If
    // baked still wins this, nothing is left for the crossover to protect.
    {
        try out.print("\n  halo, distinct silhouettes redrawn every frame (blur 24, 100x60 each)\n", .{});
        try out.print("  shapes   sdf/frame  baked/frame  bakes/frame  stencils\n", .{});
        for ([_]usize{ 2, 6, 8, 10, 16 }) |k| {
            const s = try measureStress(io, gpa, .sdf, k, 10);
            const b = try measureStress(io, gpa, .baked, k, 10);
            try out.print("  {d:>6}  {d:>8.3}ms  {d:>9.3}ms  {d:>11}  {d:>8}\n", .{
                k,
                @as(f64, @floatFromInt(s.ns)) / 1e6,
                @as(f64, @floatFromInt(b.ns)) / 1e6,
                b.bakes / 10,
                b.stencils,
            });
        }
    }

    try out.flush();
}
