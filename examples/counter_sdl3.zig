const std = @import("std");
const elmz = @import("elmz");
const runner = @import("runner");
const sdl = @import("platform_sdl3");

const app = .{
    .title = "elmz counter",
    .size = .{ .w = 420, .h = 300 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

const Msg = enum { dec, inc, reset };

const Model = struct {
    count: i32 = 0,
    presses: u32 = 0,
};

fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .dec => m.count -= 1,
        .inc => m.count += 1,
        .reset => m.count = 0,
    }
    m.presses += 1;
    return .{};
}

fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const dec = ui.button(.{ .label = "-", .msg = .dec, .width = 56 });
    const inc = ui.button(.{ .label = "+", .msg = .inc, .width = 56 });
    const reset = ui.button(.{ .label = "reset", .msg = .reset, .width = 92 });
    inc.margin_left = 8;
    reset.margin_left = 14;
    const acts = ui.row(.{ .children = &.{ dec, inc, reset } });

    const count = ui.textFmt("{d}", .{m.count}, 42);
    count.margin_top = 10;
    acts.margin_top = 8;
    const tally = ui.textFmt("{d} press(es), {d} primitives-ish", .{ m.presses, m.count }, 12);
    tally.margin_top = 10;

    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "ELMZ", .size = 22 }),
        ui.text(.{ .label = "an elm-shaped runtime, zig 0.16", .size = 12, .tone = .muted }),
        count,
        acts,
        ui.bar(.{ .value = @as(f32, @floatFromInt(m.count + 3)) / 8.0, .margin_top = 16 }),
        tally,
    }, .style = .{ .pad = 24 } });
}

pub fn main(init: std.process.Init) !void {
    var w = try sdl.Windows.init(app.title, app.size.w, app.size.h);
    defer w.deinit();
    _ = try runner.runApp(app, init.gpa, init.io, w.asWindow());
}
