const std = @import("std");
const elmz = @import("elmz");
const sdl = @import("platform_sdl3");

pub const app = .{
    .title = "elmz",
    .size = .{ .w = 420, .h = 210 },
    .Model = Model,
    .model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    .theme_path = @as(?[]const u8, "examples-theme.zon"),
};

pub const Msg = enum { dec, inc, reset };

pub const Model = struct {
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
    const base = "base";

    const inc = ui.button(.{
        .label = "+",
        .msg = .inc,
        .style = .{
            .name = base,
            .width = 56,
            .margin_left = 0,
        }
    });
    const dec = ui.button(.{
        .label = "-",
        .msg = .dec,
        .style = .{
            .name = base,
            .width = 56,
        }
    });
    const reset = ui.button(.{
        .label = "reset",
        .msg = .reset,
        .style = .{
            .name = base,
            .width = 92,
        },
    });
    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "ELMZ", .style = .{ .name = base, .size = 22 }, .size = 22}),
        ui.text(.{ .label = "an elm-shaped runtime, zig 0.16", .style = .{ .name = base, .size = 12}, .tone = .muted }),
        ui.text(.{ .label = ui.fmt("{d}", .{m.count}), .style = .{ .name = base }}),
        ui.row(.{ .children = &.{ inc, dec, reset }, .style = .{ .name = base }}),
        ui.bar(.{ .value = @as(f32, @floatFromInt(m.count + 3)) / 8.0, .margin_top = 16 }),
    }, .style = .{ .pad = 24 } });
}

pub fn main(init: std.process.Init) !void {
    const window = try elmz.init(app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer window.destroy();
    _ = try window.run();
}
