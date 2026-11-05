//! The glow demo in a real window — and nothing else. No SDL in this file.

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("glow.zig");

pub fn main(init: std.process.Init) !void {
    // Same entry-point shape as the headless examples: the runtime supplies the
    // allocator and the io handle, so there is exactly one way to start an elmz
    // program. `init.io` is what the runner uses for theme polling.
    const gpa = init.gpa;

    var platform = try sdl.Windows.init(app.app.title, app.app.size.w, app.app.size.h);
    defer platform.deinit();

    _ = try runner.runAppEnv(app.app, gpa, init.io, init.environ_map, platform.asWindow());
}
