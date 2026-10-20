//! The glow demo in a real window — and nothing else.
//!
//! No SDL in this file. It composes the app (`glow.zig`, where `view` lives),
//! a rasterizer (`software`), and a platform (`platform_sdl3`), then hands the
//! loop to `runner`. Swapping SDL for a wl_shm backend later is a one-line
//! change here.
//!
//! What to look for on screen: two buttons that are the same button. The left
//! one asks the distance field for its halo, the right one asks for a baked
//! stencil; same colour, same blur, same spread. If they ever look different,
//! the two renderers disagree — which is the only reason they are side by side.
//!
//! Drop a `theme.zon` next to the binary and the whole room recolours on save,
//! halos included.
//!
//!   zig build run-glow-sdl3      (needs libsdl3-dev)

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

    _ = try runner.runApp(app.app, gpa, init.io, platform.asWindow());
}
