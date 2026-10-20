//! Corner radii in a real window.
//!
//! The same `view` as the headless example, with a pointer attached -- which is
//! what makes it worth a window: rounded hit testing is a claim about where a
//! click COUNTS, and the only way to check that is to click the corner and see
//! whether anything happens. A picture cannot answer it.
//!
//!   zig build run-radius-sdl3      (needs libsdl3-dev)

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("radius.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var platform = try sdl.Windows.init(app.app.title, app.app.size.w, app.app.size.h);
    defer platform.deinit();

    _ = try runner.runApp(app.app, gpa, init.io, platform.asWindow());
}
