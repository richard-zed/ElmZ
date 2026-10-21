//! Panes in a real window — and nothing else.
//!
//! No SDL in this file. It composes the app (`panes.zig`, where
//! `update`/`view` live), a rasterizer (`software`), and a platform
//! (`platform_sdl3`), then hands the loop to `runner`.
//!
//! Wheel over the list scrolls it, the thumb drags, Tab walks the named
//! controls, and a click on empty space — or Escape — closes the popup. The
//! popup itself is a zero-height stack child, so it costs no layout space and
//! its click still wins over the page underneath.
//!
//!   zig build run-panes-sdl3      (needs libsdl3-dev)

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("panes.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var platform = try sdl.Windows.init(app.app.title, app.app.size.w, app.app.size.h);
    defer platform.deinit();

    _ = try runner.runApp(app.app, gpa, init.io, platform.asWindow());
}
