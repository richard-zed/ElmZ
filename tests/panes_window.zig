//! Panes in a real window — and nothing else. No SDL in this file.

const std = @import("std");
const sdl = @import("platform_sdl3");
const app = @import("panes.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var w = try elmz.init(app.app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer w.deinit();
    _ = try w.run();
}
