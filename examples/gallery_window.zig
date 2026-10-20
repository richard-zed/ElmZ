//! The gallery, in an SDL3 window. No SDL types here — same composition as
//! counter_window.zig, just a bigger app.
//!
//!   zig build run-gallery-sdl3

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("gallery.zig");

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
