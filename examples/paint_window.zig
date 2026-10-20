//! The fills demo in a real window — and nothing else.
//!
//! No SDL in this file. It composes the app (`paint.zig`, where `view` lives),
//! a rasterizer (`software`), and a platform (`platform_sdl3`), then hands the
//! loop to `runner`. Swapping SDL for a wl_shm backend later is a one-line
//! change here.
//!
//! What to look for on screen: the borders in the second row are the honest
//! test. A square gradient border cannot be four 1px quads, so it is stroked
//! through the SDF against the element rect and ramps around the whole outline.
//!
//!   zig build run-paint-sdl3      (needs libsdl3-dev)

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("paint.zig");

pub fn main(init: std.process.Init) !void {
    // Same entry-point shape as the headless examples: the runtime supplies
    // the allocator and the io handle, so there is exactly one way to start
    // an elmz program. `init.io` is what the runner will use for theme
    // polling and a frame clock; it is threaded now, consumed later.
    const gpa = init.gpa;

    var platform = try sdl.Windows.init(app.app.title, app.app.size.w, app.app.size.h);
    defer platform.deinit();

    // No status print. `std.debug.print` initializes the stderr writer, which
    // scans the raw environment block on first use (std.Io.Threaded.Environ.scan)
    // and panics on a null entry. A launcher-supplied environment is not ours to
    // assume well-formed, and nothing about a GUI app's exit should depend on
    // stderr being usable. The window is the output.
    _ = try runner.runApp(app.app, gpa, init.io, platform.asWindow());
}
