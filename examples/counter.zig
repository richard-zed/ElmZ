const std = @import("std");
const elmz = @import("elmz");
const sdl = @import("platform_sdl3");

const app = .{
    .title = "ElmZ Examples",
    .size = .{ .w = 420, .h = 210 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

const Msg = enum { dec, inc, reset };

const Model = struct {
    count: i8 = 0,
    presses: u8 = 0,
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
    return ui.column(.{ .children = &.{
        ui.text(.{ .label = "ElmZ",
            .style = .{
                .name = "base",
                .size = 24,
            },
        }),
        ui.text(.{ .label = "an elm-shaped runtime, zig 0.17",
            .style = .{
                .name = "base",
                .size = 12,
                .tone = .muted,
            }
        }),
        ui.text(.{ .label = ui.fmt("{d}", .{m.count}),
            .style = .{
                .name = "base",
                .size = 18,
            }
        }),
        ui.row(.{ .children = &.{
            ui.button(.{ .label = "+", .msg = .inc,
                .style = .{
                    .name = "base",
                    .width = 56,
                    .margin_left = 0,
                }
            }),
            ui.button(.{ .label = "-", .msg = .dec,
                .style = .{
                    .name = "base",
                    .width = 56,
                }
            }),
            ui.button(.{ .label = "reset", .msg = .reset,
                .style = .{
                    .name = "base",
                    .width = 92,
                },
            }),
        }}),
        ui.bar(.{ .value = @as(f32, @floatFromInt(m.count + 3)) / 8.0, .margin_top = 16 }),
    }, .style = .{ .pad = 18 } });
}

pub fn main(init: std.process.Init) !void {
    const window = try elmz.init(app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer window.destroy();
    _ = try window.run();
}
