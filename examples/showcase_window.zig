//! The showcase in a real window — and nothing else.
//!
//! No SDL in this file. It composes the app (`showcase.zig`, where
//! `update`/`view` live), a rasterizer (`software`), and a platform
//! (`platform_sdl3`), then hands the loop to `runner`.
//!
//! This is the one to open if you want to see the library doing everything at
//! once: gradient title text, nav tabs where `selected` must read as live
//! against its `control` neighbours, a panel card with hit regions, a gradient
//! bar, a gradient border, a primary button, and a disabled button that must
//! neither light up nor swallow the click. Move the pointer onto the buttons
//! and the hover fill is DERIVED by the frame, never set on the element.
//!
//! Because `showcase.zig` declares a `theme_path`, the runner watches
//! `theme.zon` and recolours live. Copy the defaults and edit a colour:
//!
//!     cp zig-out/bin/theme.defaults.zon zig-out/bin/theme.zon   (beside the exe)
//!     zig build run-showcase-sdl3
//!
//! then edit a colour and the window follows. Break it on purpose — set
//! `.hover` equal to `.control` — and the band reports the loader's own
//! file:line diagnostic instead of the app going quiet.
//!
//!   zig build run-showcase-sdl3      (needs libsdl3-dev)

const std = @import("std");
const runner = @import("runner");
const sdl = @import("platform_sdl3");
const app = @import("showcase.zig");

pub fn main(init: std.process.Init) !void {
    // Same entry-point shape as the headless examples: the runtime supplies
    // the allocator and the io handle. `init.io` is what the runner uses for
    // theme polling; on the headless side the same handle writes the PNGs.
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
