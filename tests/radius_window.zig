//! Corner radii in a real window.

const std = @import("std");
const sdl = @import("platform_sdl3");
const app = @import("radius.zig");
const elmz = @import("elmz");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const w = try elmz.init(app.app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer w.destroy();
    _ = try w.run();
}
