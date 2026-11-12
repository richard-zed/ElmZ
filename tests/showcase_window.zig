//! The showcase in a real window — and nothing else. No SDL in this file.

const std = @import("std");
const sdl = @import("platform_sdl3");
const app = @import("showcase.zig");
const elmz = @import("elmz");

pub fn main(init: std.process.Init) !void {
    // Same entry-point shape as the headless examples: the runtime supplies
    // the allocator and the io handle. `init.io` is what the runner uses for
    // theme polling; on the headless side the same handle writes the PNGs.
    const gpa = init.gpa;

    // No status print. `std.debug.print` initializes the stderr writer, which
    // scans the raw environment block on first use (std.Io.Threaded.Environ.scan)
    // and panics on a null entry. A launcher-supplied environment is not ours to
    // assume well-formed, and nothing about a GUI app's exit should depend on
    // stderr being usable. The window is the output.
    const w = try elmz.init(app.app, sdl.Windows, init.gpa, init.io, init.environ_map);
    defer w.destroy();
    _ = try w.run();
}
