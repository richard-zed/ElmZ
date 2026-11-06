//! Corner radii in a real window.

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("radius.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var platform = try sdl.Windows.init(app.app.title, app.app.size.w, app.app.size.h);
    defer platform.deinit();

    _ = try runner.runAppEnv(app.app, gpa, init.io, init.environ_map, platform.asWindow());
}
