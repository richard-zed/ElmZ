const std = @import("std");
const elmz = @import("elmz");
const runner = @import("runner");
const sdl = @import("platform_sdl3");

const app = .{
    .title = "elmz",
    .size = .{ .w = 420, .h = 300 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    .theme_path = @as(?[]const u8, "theme.zon"),
};

const Msg = enum { dec, inc, reset };

const Model = struct {
    count: i32 = 0,
    presses: u32 = 0,
};

fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .inc => m.count += 1,
        .dec => m.count -= 1,
        .reset => m.count = 0,
    }
    m.presses += 1;
    return .{};
}

fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const inc = ui.button(.{ .label = "+",
        .msg = .inc,
        .width = 56 });
    const dec = ui.button(.{ .label = "-",
        .msg = .dec,
        .width = 56,
        .margin_left = 8
    });
    const reset = ui.button(.{ .label = "reset", .msg = .reset, .width = 92, .margin_left = 8 });
    const base = ui.styleByName("base") orelse unreachable;
    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "ELMZ", .style = base, .size = 22 }),
        ui.text(.{ .label = "an elm-shaped runtime, zig 0.16",
                         .size = 12,
                         .tone = .muted }),
        ui.text(.{ .label = ui.fmt("{d}", .{m.count}),
                         .size = 42,
                         .margin_top = 10 }),
        ui.row(.{ .children = &.{ inc, dec, reset }, .margin_top = 8 }),
        ui.bar(.{ .value = @as(f32, @floatFromInt(m.count + 3)) / 8.0, .margin_top = 16 }),
    }, .style = .{ .pad = 24 } });
}

pub fn main(init: std.process.Init) !void {
    var w = try sdl.Windows.init(app.title, app.size.w, app.size.h);
    defer w.deinit();
    _ = try runner.runAppEnv(app, init.gpa, init.io, init.environ_map, w.asWindow());
}
