//! A complete app, written the way user code is meant to look: a model, a
//! message type, one update, one view. No allocators, no pointers to free, no
//! backend, no platform.
//!
//!   zig build run-tasks          headless -> tasks_0.png, tasks_1.png
//!   zig build run-tasks-sdl3   the same app in an SDL3 window

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .title = "tasks",
    .size = .{ .w = 360, .h = 268 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

pub const Item = struct { label: []const u8, done: bool = false };

pub const Msg = union(enum) {
    toggle: usize,
    reset,
};

pub const Model = struct {
    items: [4]Item = .{
        .{ .label = "flour tortillas" },
        .{ .label = "peanut butter", .done = true },
        .{ .label = "refried beans" },
        .{ .label = "oatmeal" },
    },
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .toggle => |i| m.items[i].done = !m.items[i].done,
        .reset => for (&m.items) |*item| {
            item.done = false;
        },
    }
    return .{};
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    var done: usize = 0;
    for (m.items) |item| {
        if (item.done) done += 1;
    }

    // one row per item, built in a loop: no hand-unrolled children
    var rows: [m.items.len]*elmz.Element(Msg) = undefined;
    for (m.items, 0..) |item, i| {
        const mark = ui.bar(.{ .value = 1 });
        mark.width = 3;
        mark.height = 14;
        mark.bg = if (item.done) ui.theme.accent else ui.theme.border;

        // done rows go FLAT (page colour) and drop to muted text instead of
        // using a dim fill: Mocha has no step between base and surface0, so a
        // "dimmer" fill was either invisible (mantle, 1.07) or identical to the
        // normal row (surface0, 1.00). The edge border keeps the row legible.
        const label = ui.text(.{ .label = item.label, .size = 14 });
        if (item.done) label.fg = ui.theme.text_muted;

        const row = ui.row(.{ .children = &.{ mark, label } });
        row.pad = 10;
        row.gap = 10;
        row.bg = if (item.done) ui.theme.bg else ui.theme.panel;
        row.border = ui.theme.border;
        row.on_press = .{ .toggle = i };
        rows[i] = row;
    }

    const list = ui.column(.{ .children = &rows });
    list.gap = 6;

    const reset = ui.button(.{ .label = "reset", .msg = .reset });
    reset.width = 68;

    const foot = ui.row(.{ .children = &.{
        ui.text(.{ .label = "click a row to toggle", .size = 10, .tone = .muted }),
        ui.spaceBefore(ui.textFmt("{d}/{d} done", .{ done, m.items.len }, 10), 10),
        ui.spaceBefore(reset, 10),
    } });

    const root = ui.column(.{ .children = &.{
        ui.text(.{ .label = "TASKS", .size = 20 }),
        ui.text(.{ .label = "one model, one update, one view", .size = 10, .tone = .muted }),
        ui.spaceBefore(list, 10),
        ui.spaceBefore(foot, 10),
    } });
    root.pad = 18;
    root.gap = 4;
    return root;
}

// ---------------------------------------------------------------------------
// headless driver: render two states to PNG so the layout is inspectable
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    // `start.zig` has already built the general purpose allocator (leak checking
    // included, in Debug) and the IO runtime. Constructing our own only
    // duplicated them -- this is where five copies of `std.Io.Threaded.init`
    // came from, in a program that never wanted a thread.
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, app.size.w, app.size.h);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    // frame 0 as declared, frame 1 after toggling two rows
    const script = [_]?Msg{ null, .{ .toggle = 0 }, .{ .toggle = 2 } };
    var shot: usize = 0;
    for (script) |maybe_msg| {
        if (maybe_msg) |msg| _ = rt.dispatch(msg);

        var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer frame.deinit();

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "tasks_{d}.png", .{shot});
        try canvas.writePng(io, gpa, name);
        try out.print("wrote {s}: {d} primitives, {d} hit regions\n", .{ name, frame.prims.len, frame.hits.len });
        shot += 1;
    }
    try out.flush();
}
