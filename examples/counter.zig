//! A counter app, driven headlessly: no window, no GPU, no event loop thread.
//! Frames are rendered to PNG so layout can be inspected without a display.
//! Swapping in a real backend means handing `Runtime.frame()` a different
//! `elmz.Renderer` and feeding it events from SDL/Mach/winit instead of the
//! script below — `update`/`view` do not change.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .font_path = "src/font.ttf",
    .title = "elmz",
    .size = .{ .w = 420, .h = 300 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    // Optional. An app that declares this gets a live theme file: the runner
    // reads it before the first frame and re-reads it when it changes. Drop a
    // `theme.zon` beside the binary and edit a colour to watch it take effect;
    // with no file present the compiled defaults stand.
    .theme_path = @as(?[]const u8, "theme.zon"),
};

const W = app.size.w;
const H = app.size.h;

pub const Msg = enum { dec, inc, reset };

pub const Model = struct {
    count: i32 = 0,
    presses: u32 = 0,
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .dec => m.count -= 1,
        .inc => m.count += 1,
        .reset => m.count = 0,
    }
    m.presses += 1;
    return .{};
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const dec = ui.button(.{ .label = "-", .msg = .dec, .width = 56 });
    const inc = ui.button(.{ .label = "+", .msg = .inc, .width = 56 });
    const reset = ui.button(.{ .label = "reset", .msg = .reset, .width = 92 });

    const acts = ui.row(.{ .children = &.{ dec, ui.spaceBefore(inc, 8), ui.spaceBefore(reset, 14) } });

    const root = ui.column(.{ .children = &.{
        ui.text(.{ .label = "ELMZ", .size = 22 }),
        ui.text(.{ .label = "an elm-shaped runtime, zig 0.16", .size = 12, .tone = .muted }),
        ui.spaceBefore(ui.textFmt("{d}", .{m.count}, 42), 10),
        ui.spaceBefore(acts, 8),
        ui.spaceBefore(ui.bar(.{ .value = @as(f32, @floatFromInt(m.count + 3)) / 8.0 }), 16),
        ui.spaceBefore(ui.textFmt("{d} press(es), {d} primitives-ish", .{ m.presses, m.count }, 12), 10),
    }, .style = .{ .pad = 24 } });
    return root;
}

/// Events, as a window backend would deliver them: a point per click.
const Script = union(enum) {
    click_msg: Msg,
    click_at: [2]f32,
};

pub fn main(init: std.process.Init) !void {
    // `start.zig` has already built the general purpose allocator (leak checking
    // included, in Debug) and the IO runtime. Constructing our own only
    // duplicated them -- this is where five copies of `std.Io.Threaded.init`
    // came from, in a program that never wanted a thread.
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);

    // Caller-owned bytes: the canvas holds a slice into them, so the
    // free is registered first and therefore runs after the teardown.
    const font_bytes = try software.loadFont(gpa, init.io, "src/font.ttf");
    defer gpa.free(font_bytes);
    canvas.setFont(font_bytes);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    const script = [_]Script{
        .{ .click_msg = .inc },
        .{ .click_msg = .inc },
        .{ .click_msg = .inc },
        .{ .click_msg = .dec },
        .{ .click_msg = .reset },
        .{ .click_at = .{ 415, 295 } }, // miss: no region, no message
    };

    for (script, 0..) |step, i| {
        var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer frame.deinit();

        try out.print("frame {d}: state=count {d}  prims={d}  hits={d}\n", .{
            i, rt.state.count, frame.primitiveCount(), frame.hits.len,
        });

        const point: [2]f32 = switch (step) {
            .click_msg => |m| blk: {
                for (frame.hits) |h| {
                    if (h.msg == m) break :blk .{
                        h.rect.x + h.rect.w / 2,
                        h.rect.y + h.rect.h / 2,
                    };
                }
                break :blk .{ 0, 0 };
            },
            .click_at => |p| p,
        };

        rt.press.down(&frame, point);
        if (rt.press.up(point)) |m| {
            _ = rt.dispatch(m);
            try out.print("  click @({d:.0},{d:.0}) -> .{s}\n", .{ point[0], point[1], @tagName(m) });
        } else {
            try out.print("  click @({d:.0},{d:.0}) -> (no hit)\n", .{ point[0], point[1] });
        }

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "frame_{d}.png", .{i});
        try canvas.writePng(io, gpa, name);
    }

    try out.print("\nfinal state: count={d} presses={d}\n", .{ rt.state.count, rt.state.presses });

    // dump the primitive stream for frame 0's shape
    var f = try rt.frame(.{ .w = @floatFromInt(W), .h = @floatFromInt(H) }, canvas.renderer());
    defer f.deinit();
    try out.print("last frame: {d} primitives\n", .{f.primitiveCount()});
    for (f.prims, 0..) |p, i| {
        if (i >= 6) {
            try out.print("  ... ({d} more)\n", .{f.prims.len - i});
            break;
        }
        var dbuf: [24]u8 = undefined;
        switch (p) {
            .quad => |q| try out.print("  quad  [{d:.0},{d:.0} {d:.0}x{d:.0}] {s}\n", .{
                q.rect.x, q.rect.y, q.rect.w, q.rect.h, fillDesc(q.fill, &dbuf),
            }),
            .frost => |q| try out.print("  frost [{d:.0},{d:.0} {d:.0}x{d:.0}] blur={d:.0}\n", .{ q.rect.x, q.rect.y, q.rect.w, q.rect.h, q.blur }),
            .halo => |q| try out.print("  halo  [{d:.0},{d:.0} {d:.0}x{d:.0}] blur={d:.0} spread={d:.0}\n", .{
                q.rect.x, q.rect.y, q.rect.w, q.rect.h, q.halo.blur, q.halo.spread,
            }),
            .rrect => |q| try out.print("  rrect [{d:.0},{d:.0} {d:.0}x{d:.0}] r={d:.0} {s}\n", .{
                q.rect.x, q.rect.y, q.rect.w, q.rect.h, q.radius, fillDesc(q.fill, &dbuf),
            }),
            .text => |t| try out.print("  text  [{d:.0},{d:.0}] {d:.0}px \"{s}\"\n", .{ t.x, t.y, t.size, t.bytes }),
        }
    }
    try out.flush();
}

/// Solid colours keep printing as hex; gradients say so, because a hex would
/// be one sample of something that is not one colour.
fn fillDesc(f: elmz.Fill, buf: *[24]u8) []const u8 {
    return switch (f) {
        .solid => |c| std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch "#??",
        .linear => "gradient/linear",
        .radial => "gradient/radial",
    };
}
