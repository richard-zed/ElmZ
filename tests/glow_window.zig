//! The glow demo in a real window — and nothing else. No SDL in this file.

const std = @import("std");
const sdl = @import("platform_sdl3");
const app = @import("glow.zig");
const elmz = @import("elmz");

pub fn main(init: std.process.Init) !void {
    // Same entry-point shape as the headless examples: the runtime supplies the
    // allocator and the io handle, so there is exactly one way to start an elmz
    // program. `init.io` is what the runner uses for theme polling.
    const gpa = init.gpa;

    const w = try elmz.init(app.app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer w.destroy();
    _ = try w.run();
}
