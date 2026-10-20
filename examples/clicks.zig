//! Click ownership, with the pointer states that make it visible.
//!
//! Hover a button and it lights up. Press it and it *stays* lit, even when the
//! cursor leaves it — because the press is owned by the region it started on.
//! While that press is in flight nothing else lights up, so dragging onto the
//! other button shows a lit A and a cold B: the picture is the rule. Release
//! over B and nothing fires; release back on A and A fires.
//!
//! Headless (`zig build run-clicks`): drives the cases, asserts both the
//! outcome and the painted colours, writes clicks.png.
//! Windowed: `zig build run-clicks-sdl3` (needs libsdl3-dev).

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .title = "elmz - click ownership",
    // Opts into the runner's theme watch: drop a theme.zon next to the
    // binary and the palette reloads on save.
    .theme_path = "theme.zon",
    .size = .{ .w = 480, .h = 420 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

const W = app.size.w;
const H = app.size.h;

pub const Msg = enum { a, b, reset };

pub const Which = enum { none, a, b };

pub const Model = struct {
    a: u32 = 0,
    b: u32 = 0,
    total: u32 = 0,
    last: Which = .none,
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .a => {
            m.a += 1;
            m.total += 1;
            m.last = .a;
        },
        .b => {
            m.b += 1;
            m.total += 1;
            m.last = .b;
        },
        .reset => m.* = .{},
    }
    return .{};
}

fn whichName(w: Which) []const u8 {
    return switch (w) {
        .none => "-",
        .a => "A",
        .b => "B",
    };
}

fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    // The last button that fired stays tinted, so a click that went nowhere
    // looks like nowhere: neither counter moves and neither button lights.
    const a = ui.button(.{ .label = "A", .msg = .a, .width = 120, .height = 56, .style = .{ .bg = if (m.last == .a) ui.theme.accent else ui.theme.control } });

    const b = ui.button(.{ .label = "B", .msg = .b, .width = 120, .height = 56, .style = .{ .bg = if (m.last == .b) ui.theme.accent else ui.theme.control } });

    const reset = ui.button(.{ .label = "reset", .msg = .reset, .width = 92 });

    const pair = ui.row(.{ .children = &.{ a, ui.spaceBefore(b, 16) } });

    const tally = ui.text(.{ .label = ui.fmt("last fired: {s}      total: {d}", .{ whichName(m.last), m.total }), .size = 12, .tone = .muted });

    const body = ui.text(.{ .label = "Hover a button and it lights up. Press it: it stays lit even if " ++
        "you drag onto the other one, and the button under the cursor " ++
        "stays dark, because the press owns the click. Release " ++
        "elsewhere and nothing fires; release back on it and it does.", .size = 12, .tone = .muted, .wrap = true });

    const root = ui.column(.{ .children = &.{
        ui.text(.{ .label = "ELMZ", .size = 22 }),
        ui.text(.{ .label = "the press owns the click, not the release", .size = 12, .tone = .muted }),
        ui.spaceBefore(pair, 14),
        ui.spaceBefore(ui.textFmt("A fired {d}  ·  B fired {d}", .{ m.a, m.b }, 18), 14),
        ui.spaceBefore(tally, 4),
        ui.spaceBefore(reset, 16),
        ui.spaceBefore(body, 18),
        ui.spaceBefore(ui.text(.{ .label = "Esc quits.", .size = 12, .tone = .muted }), 12),
    }, .style = .{ .pad = 24 } });
    return root;
}

// ---------------------------------------------------------------------------
// headless driver: the same app, asserting instead of showing
// ---------------------------------------------------------------------------

const Target = union(enum) {
    /// centre of the hit region carrying this message
    msg: Msg,
    /// a raw point, for presses and releases that should land on nothing
    at: [2]f32,
};

const Step = struct {
    label: []const u8,
    down: Target,
    up: Target,
    /// state expected after the release
    a: u32,
    b: u32,
};

pub fn main(init: std.process.Init) !void {
    // `start.zig` has already built the general purpose allocator (leak checking
    // included, in Debug) and the IO runtime. Constructing our own only
    // duplicated them -- this is where five copies of `std.Io.Threaded.init`
    // came from, in a program that never wanted a thread.
    const gpa = init.gpa;
    const io = init.io;

    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    // ---- where the buttons are -------------------------------------------
    var probe = try rt.frame(.{ .w = @floatFromInt(W), .h = @floatFromInt(H) }, canvas.renderer());
    defer probe.deinit();
    const ra = rectOf(probe.hits, .a);
    const rb = rectOf(probe.hits, .b);
    const pa = centre(ra);
    const pb = centre(rb);

    try out.print("hit regions ({d}):\n", .{probe.hits.len});
    for (probe.hits) |h| {
        try out.print("  {s:<6} x={d:.0} y={d:.0} w={d:.0} h={d:.0}\n", .{
            @tagName(h.msg), h.rect.x, h.rect.y, h.rect.w, h.rect.h,
        });
    }

    // ---- 1. hover and press appearance -----------------------------------
    const sa = [2]f32{ ra.x + 6, ra.y + 6 };
    const sb = [2]f32{ rb.x + 6, rb.y + 6 };
    const theme = rt.ui.theme;

    const Visual = struct {
        name: []const u8,
        pos: ?[2]f32 = null,
        /// press here first, through the real hit test, and leave it held
        press_at: ?[2]f32 = null,
        at: [2]f32,
        want: elmz.Color,
    };
    const visuals = [_]Visual{
        .{ .name = "cursor over A: A hovers", .pos = pa, .at = sa, .want = theme.hover },
        .{ .name = "cursor over A: B is cold", .pos = pa, .at = sb, .want = theme.control },
        .{ .name = "cursor over B: B hovers", .pos = pb, .at = sb, .want = theme.hover },
        // press owned by A, cursor dragged onto B
        .{ .name = "press A + cursor on B: A stays pressed", .pos = pb, .press_at = pa, .at = sa, .want = theme.pressed },
        .{ .name = "press A + cursor on B: B stays cold", .pos = pb, .press_at = pa, .at = sb, .want = theme.control },
    };

    var failed: usize = 0;
    try out.print("\nappearance:\n", .{});
    for (visuals) |v| {
        try stage(&rt, &canvas, v.pos, v.press_at);
        const got = sample(&canvas, v.at);
        const ok = got.r == v.want.r and got.g == v.want.g and got.b == v.want.b;
        if (!ok) failed += 1;
        try out.print("  {s:<42} #{x:0>2}{x:0>2}{x:0>2} want #{x:0>2}{x:0>2}{x:0>2}  {s}\n", .{
            v.name, got.r, got.g, got.b, v.want.r, v.want.g, v.want.b, if (ok) "ok" else "WRONG",
        });
    }
    // Pictures of the two states worth eyeballing.
    try stage(&rt, &canvas, pa, null);
    try canvas.writePng(io, gpa, "clicks_hover.png");
    try stage(&rt, &canvas, pb, pa);
    try canvas.writePng(io, gpa, "clicks_press.png");
    try stage(&rt, &canvas, null, null);

    // ---- 2. what a click actually dispatches -----------------------------
    const steps = [_]Step{
        .{ .label = "press A, release on A", .down = .{ .msg = .a }, .up = .{ .msg = .a }, .a = 1, .b = 0 },
        .{ .label = "press A, release on B", .down = .{ .msg = .a }, .up = .{ .msg = .b }, .a = 1, .b = 0 },
        .{ .label = "press empty, release on B", .down = .{ .at = .{ W - 6, H - 6 } }, .up = .{ .msg = .b }, .a = 1, .b = 0 },
        .{ .label = "press B, release on B", .down = .{ .msg = .b }, .up = .{ .msg = .b }, .a = 1, .b = 1 },
        .{ .label = "press B, release on nothing", .down = .{ .msg = .b }, .up = .{ .at = .{ W - 6, H - 6 } }, .a = 1, .b = 1 },
        .{ .label = "press reset, release on reset", .down = .{ .msg = .reset }, .up = .{ .msg = .reset }, .a = 0, .b = 0 },
    };

    try out.print("\nclicks:\n", .{});
    for (steps, 0..) |step, i| {
        var frame = try rt.frame(.{ .w = @floatFromInt(W), .h = @floatFromInt(H) }, canvas.renderer());
        defer frame.deinit();

        const dp = resolve(frame.hits, step.down);
        const up = resolve(frame.hits, step.up);

        rt.pointer.pos = dp;
        rt.press.down(&frame, dp);
        rt.pointer.pos = up;
        const fired: ?Msg = rt.press.up(up);
        if (fired) |m| _ = rt.dispatch(m);

        const ok = rt.state.a == step.a and rt.state.b == step.b;
        if (!ok) failed += 1;

        try out.print("  {d}. {s:<28} down@({d:.0},{d:.0}) up@({d:.0},{d:.0}) -> {s:<6} A={d} B={d}  {s}\n", .{
            i + 1,                                  step.label,
            dp[0],                                  dp[1],
            up[0],                                  up[1],
            if (fired) |m| @tagName(m) else "none", rt.state.a,
            rt.state.b,                             if (ok) "ok" else "WRONG",
        });
    }

    // ---- 3. one picture of the end state ---------------------------------
    try runner.paintOnce(Model, Msg, &rt, &canvas);
    try canvas.writePng(io, gpa, "clicks.png");

    // ---- 3. the release that never comes --------------------------------
    // The platform takes the gesture away mid-press (focus lost, or the drag
    // left the window). The claim has to die with it, or the button stays lit
    // for the rest of the session and the next press silently inherits it.
    try out.print("\ncancel:\n", .{});
    {
        var frame = try rt.frame(.{ .w = @floatFromInt(W), .h = @floatFromInt(H) }, canvas.renderer());
        rt.press.down(&frame, pa); // claim A
        frame.deinit();
        rt.press.cancel(); // ...and the platform withdraws it
        const fired: ?Msg = rt.press.up(pa); // a stray release arrives anyway
        const ok = fired == null;
        if (!ok) failed += 1;
        try out.print("  press A, cancelled, release on A  -> {s:<6} {s}\n", .{
            if (fired) |m| @tagName(m) else "none", if (ok) "ok" else "WRONG",
        });
    }

    try out.print("\nfinal: A={d} B={d} total={d} last={s}\n", .{
        rt.state.a, rt.state.b, rt.state.total, whichName(rt.state.last),
    });
    var f = try rt.frame(.{ .w = @floatFromInt(W), .h = @floatFromInt(H) }, canvas.renderer());
    defer f.deinit();
    const maxy = lowestEdge(f.prims);
    try out.print("layout: lowest drawn edge y={d:.0} of {d}  ({s})\n", .{
        maxy, H, if (maxy <= H) "fits" else "OVERFLOWS",
    });
    try out.print("clicks.png written; {d} case(s) failed\n", .{failed});
    try out.flush();

    if (failed != 0) return error.ClickSemantics;
}

/// Lowest drawn edge. `Primitive.clipOf` is the scissor rect, not the shape,
/// so it says nothing about where ink landed -- and at the root it is the
/// unbounded sentinel.
fn lowestEdge(prims: []const elmz.Primitive) f32 {
    var maxy: f32 = 0;
    for (prims) |pr| switch (pr) {
        .quad => |q| maxy = @max(maxy, q.rect.y + q.rect.h),
        .rrect => |q| maxy = @max(maxy, q.rect.y + q.rect.h),
        .text => |t| maxy = @max(maxy, t.y + t.size * 1.3),
        // A halo is not drawn content for this check: it is deliberately
        // allowed outside the element, so counting it would fail the layout
        // assertion for the one feature that is supposed to overflow.
        .halo => {},
        // A frost does not move ink either: it recolours what is already there.
        .frost => {},
    };
    return maxy;
}

/// Puts the runtime into the state a case describes: an optional press (taken
/// through the real hit test, never a forged rect), then the cursor position,
/// then a repaint. The press survives the frame it was taken against, which is
/// the whole point of `Press` copying its hit out.
fn stage(
    rt: *elmz.Runtime(Model, Msg),
    canvas: *software.Canvas,
    pos: ?[2]f32,
    press_at: ?[2]f32,
) !void {
    rt.press.cancel();
    rt.pointer = .{};
    if (press_at) |p| {
        var f = try rt.frame(.{ .w = @floatFromInt(W), .h = @floatFromInt(H) }, canvas.renderer());
        defer f.deinit();
        rt.press.down(&f, p);
    }
    rt.pointer = .{ .pos = pos };
    try runner.paintOnce(Model, Msg, rt, canvas);
}

fn sample(canvas: *software.Canvas, p: [2]f32) elmz.Color {
    const x: usize = @intFromFloat(p[0]);
    const y: usize = @intFromFloat(p[1]);
    const i = (y * canvas.w + x) * 4;
    return .{ .r = canvas.px[i], .g = canvas.px[i + 1], .b = canvas.px[i + 2], .a = canvas.px[i + 3] };
}

fn rectOf(hits: []const elmz.Hit(Msg), m: Msg) elmz.Rect {
    for (hits) |h| if (h.msg == m) return h.rect;
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

fn centre(r: elmz.Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

fn resolve(hits: []const elmz.Hit(Msg), t: Target) [2]f32 {
    return switch (t) {
        .at => |p| p,
        .msg => |m| centre(rectOf(hits, m)),
    };
}
