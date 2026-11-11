//! Corner radii in a real window.

const std = @import("std");
const sdl = @import("platform_sdl3");
const app = @import("radius.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var w = try elmz.init(app.app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer w.deinit();
    _ = try w.run();
}
