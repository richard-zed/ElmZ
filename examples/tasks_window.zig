//! The tasks app in a window. That is the whole file: the app supplies its own
//! size, background and runtime; this adds a platform.
//!
//!   zig build run-tasks-sdl3      (needs SDL3)

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("tasks.zig");

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
