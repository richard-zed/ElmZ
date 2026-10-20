//! The composition layer.
//!
//! It owns the loop — poll an event, hit-test it against the frame that is on
//! screen, dispatch the message, repaint if the runtime asks — and it knows
//! exactly three things: an `elmz.Runtime`, a `software.Canvas`, and an
//! `elmz.Window`. No platform types appear here, so swapping SDL3 for a
//! Wayland `wl_shm` backend (or a test harness) changes nothing above it.

const std = @import("std");
const builtin = @import("builtin");
const elmz = @import("elmz");
const software = @import("software");

/// Whether the overlay is compiled in by default. Debug builds get it, release
/// builds do not: `zig build -Doptimize=ReleaseFast` is the difference between
/// measuring and shipping, and this is the one thing that should follow it.
pub const default_overlay = builtin.mode == .Debug;

/// What the overlay has to say. Flat on purpose -- this is the diagnostic
/// struct, not a model, and it is written and read in one place.
pub const OverlayStats = struct {
    frame_ns: u64 = 0,
    build_ns: u64 = 0,
    paint_ns: u64 = 0,
    mean_ns: u64 = 0,
    prims: usize = 0,
    hits: usize = 0,
};

/// Rolling window of PAINTED frame durations.
///
/// Per repaint, not per loop pass: an idle window is not drawing 1000 frames a
/// second, and averaging the idle poll in would report a rate nobody sees. The
/// number this produces is "how long a frame takes when one is drawn", which
/// is the number that decides whether the app feels smooth.
pub const FrameRing = struct {
    pub const capacity = 60;
    ns: [capacity]u64 = [_]u64{0} ** capacity,
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *FrameRing, v: u64) void {
        self.ns[self.head] = v;
        self.head = (self.head + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    pub fn meanNs(self: *const FrameRing) u64 {
        if (self.len == 0) return 0;
        var sum: u64 = 0;
        for (self.ns, 0..) |v, i| {
            if (i < self.len) sum += v;
        }
        return sum / self.len;
    }

    pub fn fps(self: *const FrameRing) f64 {
        const m = self.meanNs();
        if (m == 0) return 0;
        return 1e9 / @as(f64, @floatFromInt(m));
    }
};

/// Four lines wedged into the top-left corner, on nothing at all.
///
/// No panel and no backing: the text is composited straight over whatever the
/// app painted, so the readout cannot hide the pixels it is there to explain.
/// That makes legibility a function of the frame underneath -- which is why it
/// is drawn in the light theme text colour with the emphasised first line, and
/// why the corner it sits in is the one least likely to hold a control.
///
/// Drawn with the renderer's own primitives rather than through a Ui tree: it
/// runs after the frame is painted and must not be able to perturb layout,
/// raise a failure band, or add hit regions a click could land on.
pub fn drawOverlay(canvas: *software.Canvas, s: OverlayStats) void {
    const pad: f32 = 3;
    const line_h: f32 = 13;
    const size: f32 = 10;
    const rows: usize = 4;
    const fg = elmz.Color{ .r = 0xcd, .g = 0xd6, .b = 0xf4, .a = 255 };
    const dim = elmz.Color{ .r = 0xa6, .g = 0xad, .b = 0xc8, .a = 255 };

    var buf: [4][48]u8 = undefined;
    const lines = [rows][]const u8{
        std.fmt.bufPrint(&buf[0], "{d:.2} ms  {d:.0} fps", .{
            @as(f64, @floatFromInt(s.frame_ns)) / 1e6,
            if (s.mean_ns == 0) 0 else 1e9 / @as(f64, @floatFromInt(s.mean_ns)),
        }) catch "?",
        std.fmt.bufPrint(&buf[1], "build {d:.2}  paint {d:.2} ms", .{
            @as(f64, @floatFromInt(s.build_ns)) / 1e6,
            @as(f64, @floatFromInt(s.paint_ns)) / 1e6,
        }) catch "?",
        std.fmt.bufPrint(&buf[2], "{d} prims  {d} hits", .{ s.prims, s.hits }) catch "?",
        std.fmt.bufPrint(&buf[3], "{d}x{d}  {s}", .{ canvas.w, canvas.h, @tagName(builtin.mode) }) catch "?",
    };

    for (lines, 0..) |line, i| {
        const y = pad + line_h * @as(f32, @floatFromInt(i));
        canvas.drawText(pad, y, size, .{ .solid = if (i == 0) fg else dim }, line);
    }
}

pub const Options = struct {
    /// Stop after this many events. null = run until the window says quit.
    max_events: ?u32 = null,
    /// Block this long in poll() before looping again. -1 = block forever.
    poll_timeout_ms: i32 = -1,
    /// Upper bound on one poll while a theme file is being watched.
    ///
    /// The stat happens at the top of the loop, so an unbounded wait means an
    /// edit is only noticed when the pointer enters the window -- the theme
    /// looks inert until you touch it. Watching therefore costs a wakeup four
    /// times a second, which is cheaper than dragging a filesystem watcher
    /// into the composition layer.
    theme_poll_ms: i32 = 250,
    /// Draw the frame readout over the painted frame. OFF by default here and
    /// turned on by `runApp` when the binary is built in Debug, because the
    /// overlay costs a timestamp pair per repaint and a text render -- fine
    /// while measuring, not something a shipped build should pay for.
    ///
    /// It needs `io` for the clock, so it silently does nothing without one.
    overlay: bool = false,
    /// Ambient io handle: mtime-polling a theme file, and (later) a frame
    /// clock for animation. null means no io was supplied -- headless carving
    /// and tests stay filesystem-free, which is a property worth keeping.
    ///
    /// Read by `ThemeWatch`. null means a theme file cannot be loaded at all,
    /// which is why an app that sets `theme_path` must supply both this and
    /// `gpa`.
    io: ?std.Io = null,
    /// Path to a theme file, relative to the *executable's directory* (an
    /// absolute path is taken as given). Loaded before the first frame and
    /// re-read when it changes on disk. See `themePathBesideExe`.
    ///
    /// `theme.defaults.zon` is watched too, whether or not this is set: it sits
    /// underneath the override, so an edit to it has to re-apply the override.
    theme_path: ?[]const u8 = null,
    /// Allocator for re-reading the theme file. Only needed with `theme_path`.
    gpa: ?std.mem.Allocator = null,
};

/// The theme chain, as the loop sees it: `theme.zon` (end user) over
/// `theme.defaults.zon` (developer) over the palette compiled into the library.
///
/// Hot reload is a stat per loop iteration, not an inotify watch: the loop
/// already blocks in poll, iterations are not hot, and a watcher would drag a
/// platform dependency into the composition layer.
///
/// The app never learns that a theme changed. It is not app state -- the next
/// frame is simply built out of different colours, which is why this can live
/// in the runner instead of in anyone's Model.
/// Watches the theme files, and resolves them through the same call startup
/// uses. Generic over the app tier for the same reason `ChainOf` is: a reload
/// that guessed `struct {}` would reject a file whose `.app` section the app
/// legitimately declared, and it would only do so *after* the first edit.
pub fn ThemeWatchOf(comptime App: type) type {
    return struct {
        const Self = @This();
        /// What a missing or broken base falls back to. Held rather than read off
        /// `ui.theme`, which is the *result* of the previous resolution.
        floor: elmz.Theme,
        /// The developer's palette, beside the binary. Absent is the normal case.
        base_path: ?[:0]const u8,
        /// The end user's override, beside the binary.
        user_path: ?[:0]const u8,
        base_stamp: ?Stamp = null,
        user_stamp: ?Stamp = null,
        base_seen: bool = false,
        user_seen: bool = false,

        pub const Stamp = struct { mtime: i128 = 0, size: u64 = 0 };

        pub fn init(floor: elmz.Theme, base_path: ?[:0]const u8, user_path: ?[:0]const u8) Self {
            return .{ .floor = floor, .base_path = base_path, .user_path = user_path };
        }

        pub fn changed(prev: Stamp, now: Stamp) bool {
            return prev.mtime != now.mtime or prev.size != now.size;
        }

        /// Whether a stat result earns a reload.
        ///
        /// A file that disappears is left alone on purpose: editors save by
        /// unlinking and renaming, so a transient absence is ordinary, and dropping
        /// the palette mid-save would flash the fallback colours at exactly the
        /// moment someone is watching them. Only a file that is there and different
        /// earns a reload.
        fn shouldReload(seen: bool, prev: ?Stamp, now: ?Stamp) bool {
            const n = now orelse return false;
            if (!seen) return true;
            const p = prev orelse return true;
            return changed(p, n);
        }

        fn stampOf(io: std.Io, path: ?[]const u8) ?Stamp {
            const p = path orelse return null;
            const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return null;
            return .{ .mtime = st.mtime.toNanoseconds(), .size = st.size };
        }

        /// Re-resolve the whole chain if either file changed. `ui` is `*Ui(Msg)`;
        /// generic because the composition layer must not know the app's message
        /// type.
        ///
        /// Both files are re-read, not just the one that moved: an override is
        /// resolved *against* the base, so a base edit has to re-apply the override
        /// -- otherwise it stays resolved against a palette that no longer exists.
        ///
        /// A broken edit keeps the last good palette and puts the diagnostic in the
        /// error band. Blanking the window you are trying to fix a colour in would
        /// be the worst possible response to a typo.
        pub fn poll(self: *Self, ui: anytype, io: std.Io, gpa: std.mem.Allocator) void {
            const base_now = stampOf(io, self.base_path);
            const user_now = stampOf(io, self.user_path);
            const base_reload = shouldReload(self.base_seen, self.base_stamp, base_now);
            const user_reload = shouldReload(self.user_seen, self.user_stamp, user_now);

            if (base_now) |st| {
                self.base_stamp = st;
                self.base_seen = true;
            }
            if (user_now) |st| {
                self.user_stamp = st;
                self.user_seen = true;
            }
            if (!base_reload and !user_reload) return;

            const chain = resolveChain(App, gpa, io, self.floor, self.base_path, self.user_path);
            ui.theme = chain.theme;
            ui.gradients = chain.gradients;
            if (chain.message()) |m| ui.failExternal(.theme, "{s}", .{m}) else ui.clearExternal();
        }
    };
}

/// The watch for an app that declares no tokens of its own.
pub const ThemeWatch = ThemeWatchOf(struct {});

/// A fully resolved chain: every file read, every overlay applied.
///
/// Generic over the app tier's type because `.app` is parsed strictly, and a
/// strict parse needs to know what it is parsing against. An app that declares
/// tokens gets `ChainOf(Tokens)`; one that does not uses the alias below and
/// its files may not contain an `.app` section.
pub fn ChainOf(comptime App: type) type {
    return struct {
        theme: elmz.Theme,
        /// Gradient overrides that came with that palette.
        gradients: elmz.Gradients = .{},
        /// The app tier, if the app declared one. Otherwise `.{}` -- and a file
        /// that writes `.app` keys is rejected rather than waved through.
        app: App = .{},
        /// A `theme.defaults.zon` supplied the base rather than the compiled floor.
        base_from_file: bool = false,
        /// The defaults file was there and would not load; `diag` says why.
        base_rejected: bool = false,
        /// A `theme.zon` supplied the override.
        user_from_file: bool = false,
        /// The override was there and would not load; `diag` says why.
        user_rejected: bool = false,
        diag: elmz.ThemeDiag = .{},

        /// The one line the band should show, or null when nothing went wrong.
        pub fn message(self: *const @This()) ?[]const u8 {
            if (self.base_rejected or self.user_rejected) return self.diag.text();
            return null;
        }
    };
}

/// The chain for an app that declares no tokens of its own.
pub const Chain = ChainOf(struct {});

/// Read `path` as sentinel-terminated text. ZON parsing wants the sentinel; a
/// file read does not hand one back.
fn readZ(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(src);
    return gpa.dupeZ(u8, src);
}

/// Resolve `theme.zon` over `theme.defaults.zon` over `floor`.
///
/// The single place a palette is decided: startup and hot reload both call this,
/// so the two cannot drift apart.
///
/// This is what makes "theming happens in `.zon`" true rather than aspirational.
/// An app author changes the house palette by editing a file next to the binary;
/// nobody has to open a `.zig`. The compiled `floor` stays underneath, so a
/// deleted or unparseable defaults file costs a diagnostic, not the whole look.
pub fn resolveChain(
    comptime App: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    floor: elmz.Theme,
    base_path: ?[]const u8,
    user_path: ?[]const u8,
) ChainOf(App) {
    var out: ChainOf(App) = .{ .theme = floor };

    // The developer's palette. A file that will not load costs a diagnostic and
    // leaves the floor in place: an app with no palette at all is not something
    // a colour typo should be able to cause.
    if (base_path) |p| {
        const name = "theme.defaults.zon";
        if (readZ(gpa, io, p)) |src| {
            defer gpa.free(src);
            if (elmz.loadTheme(App, gpa, name, src, out.theme, &out.diag)) |loaded| {
                out.theme = loaded.theme;
                out.gradients = loaded.gradients;
                out.app = loaded.app;
                out.base_from_file = true;
            } else |_| out.base_rejected = true;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => {
                out.diag.set("{s}: {t}", .{ name, e });
                out.base_rejected = true;
            },
        }
    }

    // The end user's override: partial by design, inheriting whatever it omits.
    if (user_path) |p| {
        const name = "theme.zon";
        if (readZ(gpa, io, p)) |src| {
            defer gpa.free(src);
            if (elmz.loadTheme(App, gpa, name, src, out.theme, &out.diag)) |loaded| {
                out.theme = loaded.theme;
                out.gradients = loaded.gradients;
                out.app = loaded.app;
                out.user_from_file = true;
            } else |_| out.user_rejected = true;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => {
                out.diag.set("{s}: {t}", .{ name, e });
                out.user_rejected = true;
            },
        }
    }

    return out;
}

/// Resolve an app's `theme_path` against the directory the executable lives in.
///
/// That is where the theme file ships, so that is where it is read from. A cwd
/// relative path would make the app's appearance depend on where it was
/// launched from -- double-clicked from a file manager and run from a terminal
/// would disagree -- and the failure is silent: no file, no theme, no error.
///
/// Returns an owned, sentinel-terminated path, or null if the executable's own
/// location could not be determined.
pub fn themePathBesideExe(gpa: std.mem.Allocator, io: std.Io, given: []const u8) ?[:0]u8 {
    if (std.fs.path.isAbsolute(given)) return gpa.dupeZ(u8, given) catch null;
    const exe = std.process.executablePathAlloc(io, gpa) catch return null;
    defer gpa.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return null;
    return std.fs.path.joinZ(gpa, &.{ dir, given }) catch null;
}

/// How long the loop may block in poll before it gets to re-stat the theme.
///
/// Never unbounded while a file is being watched, and a command in flight keeps
/// its 5ms budget -- blocking for a theme would starve the async result, which
/// is the same bug in a different costume.
fn effectiveTimeout(opts: Options, busy: bool, watching: bool) i32 {
    if (busy) return 5;
    if (!watching) return opts.poll_timeout_ms;
    if (opts.poll_timeout_ms < 0) return opts.theme_poll_ms;
    return @min(opts.poll_timeout_ms, opts.theme_poll_ms);
}

pub const Stats = struct {
    frames: u32 = 0,
    events: u32 = 0,
    messages: u32 = 0,
};

/// Compose a whole app onto a window backend.
///
/// Everything the glue files used to duplicate -- canvas size, background
/// colour, runtime construction -- is derived from the app declaration, so
/// those values exist once and cannot drift apart.
///
/// `app` is a comptime struct literal with: title, size, Model, Msg,
/// update, view, and optionally `state` (initial model).
pub fn runApp(app: anytype, gpa: std.mem.Allocator, io: ?std.Io, window: elmz.Window) !Stats {
    const S = app.Model;
    const M = app.Msg;

    var canvas = try software.Canvas.init(gpa, @intCast(app.size.w), @intCast(app.size.h));
    defer canvas.deinit();

    var rt = if (@hasField(@TypeOf(app), "state"))
        elmz.Runtime(S, M).init(gpa, app.state, app.update, app.view)
    else
        elmz.Runtime(S, M).init(gpa, .{}, app.update, app.view);
    defer rt.deinit();

    var opts: Options = .{ .io = io, .gpa = gpa, .overlay = default_overlay };
    // Same optional-field trick as `state`: an app that wants a theme file
    // declares `theme_path` in its struct, and one that does not never sees it.
    if (@hasField(@TypeOf(app), "theme_path")) opts.theme_path = app.theme_path;

    // Same trick again, for the type rather than a value: an app that wants
    // tokens in its theme file names the struct here (`theme_tokens = Tokens`),
    // and its `.app` section is then parsed and checked against it. Without it
    // there is no tier and a file writing one is told so, which is the whole
    // point of declaring.
    //
    // What this does NOT do is hand the values back. Declaring `theme_tokens`
    // buys validation, not delivery: `run` passes `.app` through unread, so an
    // app that wants the numbers resolves the chain itself (see
    // `resolveChain`). Stated here because the declaration reads as though the
    // runner would deliver them, and two resolutions of one file are worth
    // knowing about before you write the second one.
    const Tokens = if (@hasField(@TypeOf(app), "theme_tokens")) app.theme_tokens else struct {};

    return run(Tokens, S, M, &rt, &canvas, window, opts);
}

/// Build a frame sized to the canvas, clear it to `bg`, and rasterise it.
/// The caller owns the returned frame.
///
/// This is the whole of "show me what this model looks like", and it was being
/// retyped in every example -- twice over, as `paint` in one and `repaint` in
/// another, differing only in whether the frame came back. Rasterising a frame
/// is not any app's business, so it lives at the composition layer, which is
/// the only place that can see both a Runtime and a Canvas.
pub fn paintInto(
    comptime S: type,
    comptime M: type,
    rt: *elmz.Runtime(S, M),
    canvas: *software.Canvas,
) !elmz.Frame(M) {
    const frame = try rt.frame(.{
        .w = @floatFromInt(canvas.w),
        .h = @floatFromInt(canvas.h),
    }, canvas.renderer());
    errdefer frame.deinit();
    canvas.clear(rt.ui.theme.bg);
    canvas.paintFrame(frame.prims);
    return frame;
}

/// Rasterise and drop the frame: for callers that only want the pixels.
///
/// Same thing `paintInto` does, minus the ownership question. Without this the
/// call site needs a `var` plus a `defer`, which is exactly the bloat this was
/// supposed to remove.
pub fn paintOnce(
    comptime S: type,
    comptime M: type,
    rt: *elmz.Runtime(S, M),
    canvas: *software.Canvas,
) !void {
    var frame = try paintInto(S, M, rt, canvas);
    defer frame.deinit();
}

pub fn run(
    comptime App: type,
    comptime S: type,
    comptime M: type,
    rt: *elmz.Runtime(S, M),
    canvas: *software.Canvas,
    window: elmz.Window,
    opts: Options,
) !Stats {
    var stats: Stats = .{};
    var frame: ?elmz.Frame(M) = null;
    errdefer if (frame) |*f| f.deinit();

    var dirty = true;
    var running = true;

    // The claim lives in `rt.press`: one owner, so the colour shown while a
    // press is in flight cannot disagree with what dispatches on release.

    // Which region the pointer is over, as of the last frame. Motion only
    // earns a repaint when this changes; sweeping across empty space is free.
    var hovered: ?elmz.Rect = null;

    // messages produced by commands land here between polls
    var async_msgs: std.ArrayList(M) = .empty;
    defer async_msgs.deinit(rt.gpa);

    // Resolved once, against the executable's own directory, and owned for the
    // life of the loop. The watch holds the resolved paths; the copies are freed
    // on the way out.
    var base_owned: ?[:0]u8 = null;
    var user_owned: ?[:0]u8 = null;
    var theme_watch: ?ThemeWatchOf(App) = null;
    defer if (opts.gpa) |g| {
        if (base_owned) |p| g.free(p);
        if (user_owned) |p| g.free(p);
    };
    if (opts.io) |io_arg| {
        if (opts.gpa) |g| {
            base_owned = themePathBesideExe(g, io_arg, "theme.defaults.zon");
            if (opts.theme_path) |given| user_owned = themePathBesideExe(g, io_arg, given);

            // Watch only when there is something to watch. A stat four times a
            // second forever is a real cost for an app that ships no theme file,
            // and a defaults file created later is a restart away.
            const base_there = if (base_owned) |p|
                (std.Io.Dir.cwd().statFile(io_arg, p, .{}) catch null) != null
            else
                false;
            if (base_there or user_owned != null) {
                theme_watch = ThemeWatchOf(App).init(rt.ui.theme, base_owned, user_owned);
                // Resolve before the first frame, through the same call the
                // loop makes on a change.
                if (theme_watch) |*w| w.poll(&rt.ui, io_arg, g);
            }
        }
    }

    var ring: FrameRing = .{};

    while (running) {
        // Before the frame is decided, so a first frame is already the right
        // colours and an edit lands on the very next paint. A failed reload
        // raises the band inside `frame()`, not here.
        if (theme_watch) |*w| {
            if (opts.io) |io_arg| {
                if (opts.gpa) |gpa_arg| {
                    const before = rt.ui.theme;
                    w.poll(&rt.ui, io_arg, gpa_arg);
                    if (!std.meta.eql(before, rt.ui.theme)) dirty = true;
                }
            }
        }
        // Command results become ordinary messages, dispatched on this thread
        // before the frame is decided -- so a completed job shows up next frame.
        async_msgs.clearRetainingCapacity();
        try rt.takeAsync(&async_msgs);
        for (async_msgs.items) |m| {
            const action = rt.dispatch(m);
            stats.messages += 1;
            if (action.quit) running = false;
            dirty = dirty or action.repaint;
        }
        if (dirty) {
            if (frame) |*f| f.deinit();
            const size = window.size();
            const clock = opts.io;
            const t0 = if (clock) |c| std.Io.Timestamp.now(c, .awake).toNanoseconds() else 0;
            frame = try rt.frame(size, canvas.renderer());
            const t1 = if (clock) |c| std.Io.Timestamp.now(c, .awake).toNanoseconds() else 0;

            canvas.clear(rt.ui.theme.bg);
            canvas.paintFrame(frame.?.prims);
            const t2 = if (clock) |c| std.Io.Timestamp.now(c, .awake).toNanoseconds() else 0;

            // Over the finished frame and under the present, so the readout
            // describes the frame underneath it rather than the previous one,
            // and so it can never end up in a PNG a headless example writes.
            if (opts.overlay and clock != null) {
                const total = t2 - t0;
                ring.push(@intCast(total));
                drawOverlay(canvas, .{
                    .frame_ns = @intCast(total),
                    .build_ns = @intCast(t1 - t0),
                    .paint_ns = @intCast(t2 - t1),
                    .mean_ns = ring.meanNs(),
                    .prims = frame.?.prims.len,
                    .hits = frame.?.hits.len,
                });
            }
            window.present(canvas.px, size);

            stats.frames += 1;
            dirty = false;
            hovered = if (rt.pointer.pos) |p| blk: {
                break :blk if (frame.?.hit(p)) |h| h.rect else null;
            } else null;
        }

        // While a command is in flight, poll briefly instead of blocking
        // forever, or its result would sit in the queue until the next input.
        const timeout = effectiveTimeout(opts, rt.asyncBusy(), theme_watch != null);
        const ev = window.poll(timeout) orelse continue;
        stats.events += 1;

        switch (ev) {
            .quit => {
                rt.press.cancel();
                running = false;
            },

            // The press claims a region; the release only counts if it comes
            // back inside that same region. Hit-testing the release point
            // alone would let a press on one button dispatch its neighbour.
            .pointer_down => |p| {
                rt.pointer.pos = p;
                // The press owns its region from here until release, and the
                // renderer colours that region -- and only that one -- until
                // then, because it paints from this same claim.
                if (frame) |*f| rt.press.down(f, p) else rt.press.cancel();
                dirty = true;
            },

            .pointer_up => |p| {
                rt.pointer.pos = p;
                dirty = true;
                if (rt.press.up(p)) |msg| {
                    const action = rt.dispatch(msg);
                    stats.messages += 1;
                    if (action.quit) running = false;
                    dirty = dirty or action.repaint;
                }
            },

            .pointer_move => |p| {
                rt.pointer.pos = p;
                if (frame) |*f| {
                    const now: ?elmz.Rect = if (f.hit(p)) |h| h.rect else null;
                    if (!sameRect(now, hovered)) {
                        hovered = now;
                        dirty = true;
                    }
                } else dirty = true;
            },

            // The release is not always going to arrive: focus can be taken
            // away, or the drag can leave the window. Dropping the claim here
            // is what stops a button staying lit for the rest of the session.
            .pointer_cancel => {
                rt.press.cancel();
                rt.pointer.pos = null;
                hovered = null;
                dirty = true;
            },

            // Keys have no destination yet: `Event` carries them, and nothing
            // dispatches. Focus is what gives them one -- a key event belongs
            // to the focused element, and there is no focus ring to consult
            // until that lands. Deliberately not marked dirty: an unhandled
            // key must not force a repaint.
            .key, .key_up => {},
        }

        if (opts.max_events) |max| {
            if (stats.events >= max) running = false;
        }
    }

    if (frame) |*f| f.deinit();
    return stats;
}

fn sameRect(a: ?elmz.Rect, b: ?elmz.Rect) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.x == y.x and x.y == y.y and x.w == y.w and x.h == y.h;
}

// ---------------------------------------------------------------------------
// tests: a fake window, so the loop is exercised with no display at all
// ---------------------------------------------------------------------------

const TMsg = enum { inc };
const TState = struct { n: i32 = 0 };

fn tUpdate(s: *TState, m: TMsg) elmz.Action(TMsg) {
    switch (m) {
        .inc => s.n += 1,
    }
    return .{};
}

fn tView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    // A row, so the button is measured at its natural width; a column would
    // stretch every child to the full inner width and hide the metrics.
    const r = ui.row(.{ .children = &.{
        ui.textFmt("{d}", .{s.n}, 20),
        ui.button(.{ .label = "inc", .msg = .inc }),
    }, .gap = 10 });
    return r;
}

const Fake = struct {
    events: []const elmz.Event,
    i: usize = 0,
    frames: u32 = 0,
    last_hash: u64 = 0,
    w: f32 = 200,
    h: f32 = 120,
    /// how many empty polls to answer before quitting, once the script runs out
    idle: usize = 0,
    spun: usize = 0,

    fn window(self: *Fake) elmz.Window {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = elmz.Window.VTable{
        .poll = poll,
        .present = present,
        .size = size,
        .deinit = noop,
    };

    fn poll(ptr: *anyopaque, _: i32) ?elmz.Event {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.i < self.events.len) {
            defer self.i += 1;
            return self.events[self.i];
        }
        // A timeout (null) keeps the loop going, which is exactly how a
        // worker's result gets drained. Then quit, so tests terminate.
        if (self.spun < self.idle) {
            self.spun += 1;
            return null;
        }
        return .quit;
    }

    fn present(ptr: *anyopaque, px: []const u8, s: elmz.Size) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        _ = s;
        self.frames += 1;
        self.last_hash = std.hash.Wyhash.hash(0, px);
    }

    fn size(ptr: *anyopaque) elmz.Size {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return .{ .w = self.w, .h = self.h };
    }

    fn noop(_: *anyopaque) void {}
};

test "runner paints once, then stops when the window says quit" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    const events = [_]elmz.Event{.quit};
    var fake: Fake = .{ .events = &events };

    const stats = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 1), stats.frames);
    try std.testing.expectEqual(@as(u32, 1), stats.events);
    try std.testing.expectEqual(@as(u32, 0), stats.messages);
    try std.testing.expect(fake.last_hash != 0);
}

test "layout measures with the glyph metrics of the drawing backend" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();

    try std.testing.expectEqual(@as(usize, 1), f.hits.len);
    const rect = f.hits[0].rect;

    // A button is label + 24px of padding, so this holds only if the *bitmap*
    // metrics reached layout: 3 chars at size 16 = 34px wide, not the nominal
    // 0.58em estimate of 27.84.
    const label = software.Canvas.measureText("inc", 16);
    try std.testing.expectApproxEqAbs(label.width + 24, rect.w, 0.01);
    try std.testing.expect(@abs(rect.w - (3 * 0.58 * 16 + 24)) > 1.0);

    // and the label is centred inside it
    var seen = false;
    for (f.prims) |p| switch (p) {
        .text => |t| {
            if (std.mem.eql(u8, t.bytes, "inc")) {
                try std.testing.expectApproxEqAbs(rect.x + (rect.w - label.width) / 2, t.x, 0.51);
                seen = true;
            }
        },
        else => {},
    };
    try std.testing.expect(seen);
}

test "a frame survives the next one being built" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var first = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer first.deinit();

    var saved: ?[]const u8 = null;
    for (first.prims) |p| switch (p) {
        .text => |t| {
            if (std.mem.eql(u8, t.bytes, "inc")) saved = t.bytes;
        },
        else => {},
    };
    try std.testing.expect(saved != null);

    // building a frame resets the UI arena; before frames copied their text
    // into their own arena, `saved` was dangling by now
    var second = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer second.deinit();

    try std.testing.expectEqualStrings("inc", saved.?);
}

test "runner hit-tests a click and routes it to update" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    // Layout is deterministic for a fixed size, so ask the runtime where the
    // button landed before scripting a click at its centre.
    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.hits.len);
    const r = probe.hits[0].rect;
    const point: [2]f32 = .{ r.x + r.w / 2, r.y + r.h / 2 };

    const events = [_]elmz.Event{
        .{ .pointer_down = point },
        .{ .pointer_up = point },
        .quit,
    };
    var fake: Fake = .{ .events = &events };

    const stats = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(i32, 1), rt.state.n);
    try std.testing.expectEqual(@as(u32, 1), stats.messages);
    try std.testing.expectEqual(@as(u32, 3), stats.frames); // initial, press tint, release
}

// ---------------------------------------------------------------------------
// async: commands run off-thread, results come back as messages
// ---------------------------------------------------------------------------

const AJob = struct { n: i32, main_id: std.Thread.Id };

const AMsg = union(enum) {
    start: *const AJob,
    done: struct { n: i32, off_thread: bool },
};

const AState = struct { got: i32 = 0, off_thread: bool = false };

fn aRun(ctx: *const anyopaque) ?AMsg {
    const job: *const AJob = @ptrCast(@alignCast(ctx));
    return .{ .done = .{
        .n = job.n * 2,
        .off_thread = std.Thread.getCurrentId() != job.main_id,
    } };
}

fn aUpdate(s: *AState, m: AMsg) elmz.Action(AMsg) {
    switch (m) {
        .start => |job| return .{ .cmd = .{ .ctx = @ptrCast(job), .run = aRun } },
        .done => |d| {
            s.got = d.n;
            s.off_thread = d.off_thread;
        },
    }
    return .{};
}

fn aView(s: *AState, ui: *elmz.Ui(AMsg)) *elmz.Element(AMsg) {
    return ui.textFmt("{d}", .{s.got}, 12);
}

test "a command runs on a worker thread and its result is dispatched" {
    const gpa = std.testing.allocator;
    var job: AJob = .{ .n = 21, .main_id = std.Thread.getCurrentId() };

    var rt = elmz.Runtime(AState, AMsg).init(gpa, .{}, aUpdate, aView);
    defer rt.deinit();

    _ = rt.dispatch(.{ .start = &job });
    const main_id = std.Thread.getCurrentId();
    try std.testing.expectEqual(main_id, job.main_id);

    var done: std.ArrayList(AMsg) = .empty;
    defer done.deinit(gpa);

    var spins: usize = 0;
    while (rt.state.got == 0 and spins < 200_000) : (spins += 1) {
        done.clearRetainingCapacity();
        try rt.takeAsync(&done);
        for (done.items) |m| _ = rt.dispatch(m);
        std.atomic.spinLoopHint();
    }

    try std.testing.expectEqual(@as(i32, 42), rt.state.got);
    // proves the body really ran somewhere else, not inline in dispatch()
    try std.testing.expect(rt.state.off_thread);
}

// ---------------------------------------------------------------------------
// phase 1: the loop itself is the thing under test
// ---------------------------------------------------------------------------

fn checkFrame(f: anytype, size: elmz.Size) !void {
    for (f.prims) |p| switch (p) {
        .halo => |h| {
            try std.testing.expect(std.math.isFinite(h.halo.blur));
            try std.testing.expect(std.math.isFinite(h.halo.spread));
        },
        .quad => |q| {
            const r = q.rect;
            try std.testing.expect(std.math.isFinite(r.x) and std.math.isFinite(r.y));
            try std.testing.expect(std.math.isFinite(r.w) and std.math.isFinite(r.h));
            try std.testing.expect(r.w >= 0 and r.h >= 0);
            try std.testing.expect(r.x >= -0.01 and r.y >= -0.01);
            try std.testing.expect(r.x + r.w <= size.w + 0.01);
            try std.testing.expect(r.y + r.h <= size.h + 0.01);
        },
        .rrect => |q| {
            const r = q.rect;
            try std.testing.expect(std.math.isFinite(r.x + r.y + r.w + r.h + q.radius));
            try std.testing.expect(r.w >= 0 and r.h >= 0);
            try std.testing.expect(q.radius >= 0);
            try std.testing.expect(r.x + r.w <= size.w + 0.01);
            try std.testing.expect(r.y + r.h <= size.h + 0.01);
        },
        .text => |t| {
            try std.testing.expect(std.math.isFinite(t.x) and std.math.isFinite(t.y));
            try std.testing.expect(t.x >= -0.01 and t.y >= -0.01);
            try std.testing.expect(t.x <= size.w and t.y <= size.h);
        },
    };
    for (f.hits) |h| {
        try std.testing.expect(h.rect.w > 0 and h.rect.h > 0);
        try std.testing.expect(h.rect.x + h.rect.w <= size.w + 0.01);
        try std.testing.expect(h.rect.y + h.rect.h <= size.h + 0.01);
    }
}

// a layout with every feature that can push a rect out of bounds
fn sView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const inner = ui.row(.{ .children = &.{
        ui.rect(.{ .width = 8, .height = 20 }),
        ui.text(.{ .label = "nested", .size = 10 }),
        ui.button(.{ .label = "inc", .msg = .inc }),
    }, .gap = 6, .style = .{ .pad = 4, .border = ui.theme.accent } });

    const box = ui.column(.{ .children = &.{
        ui.text(.{ .label = "stress", .size = 14 }),
        ui.spaceBefore(inner, 4),
        ui.bar(.{ .value = 0.5 }),
    }, .gap = 2, .style = .{ .pad = 10, .bg = ui.theme.panel, .border = ui.theme.text_muted } });
    return box;
}

test "no frame escapes the canvas: finite, non-negative, in bounds" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 240, 200);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{ .n = 7 }, tUpdate, sView);
    defer rt.deinit();

    // Big enough for the content: every rect must be inside the canvas.
    var f = try rt.frame(.{ .w = 240, .h = 200 }, canvas.renderer());
    defer f.deinit();
    try checkFrame(f, .{ .w = 240, .h = 200 });

    // Smaller than the content: layout overflows on purpose (there is no clip
    // rect yet), so the guarantee is only that it stays finite and that
    // painting it is safe. Tighten this to checkFrame once clipping lands.
    var small = try software.Canvas.init(gpa, 90, 70);
    defer small.deinit();
    var g = try rt.frame(.{ .w = 90, .h = 70 }, small.renderer());
    defer g.deinit();
    for (g.prims) |p| switch (p) {
        .quad => |q| try std.testing.expect(std.math.isFinite(q.rect.x + q.rect.y + q.rect.w + q.rect.h)),
        .rrect => |q| try std.testing.expect(std.math.isFinite(q.rect.x + q.rect.w + q.radius)),
        .text => |t| try std.testing.expect(std.math.isFinite(t.x + t.y)),
        .halo => |h| try std.testing.expect(std.math.isFinite(h.rect.x + h.halo.blur)),
    };
    small.paintFrame(g.prims);
    var lit: usize = 0;
    for (small.px) |b| {
        if (b != 0) lit += 1;
    }
    try std.testing.expect(lit > 0); // it did paint, clipped to the canvas
}

// app whose only message source after the click is a command
const CState = struct { job: *const AJob, got: i32 = 0, clicks: u32 = 0 };
const CMsg = union(enum) { press, done: i32 };

fn cRun(ctx: *const anyopaque) ?CMsg {
    const job: *const AJob = @ptrCast(@alignCast(ctx));
    return .{ .done = job.n * 2 };
}

fn cUpdate(s: *CState, m: CMsg) elmz.Action(CMsg) {
    switch (m) {
        .press => {
            s.clicks += 1;
            return .{ .cmd = .{ .ctx = @ptrCast(s.job), .run = cRun } };
        },
        .done => |n| s.got = n,
    }
    return .{};
}

fn cView(s: *CState, ui: *elmz.Ui(CMsg)) *elmz.Element(CMsg) {
    return ui.row(.{ .children = &.{
        ui.textFmt("{d}", .{s.got}, 12),
        ui.button(.{ .label = "go", .msg = .{ .press = {} } }),
    } });
}

test "run() drains a command's result while polling, with no further events" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var job: AJob = .{ .n = 21, .main_id = std.Thread.getCurrentId() };
    var rt = elmz.Runtime(CState, CMsg).init(gpa, .{ .job = &job }, cUpdate, cView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.hits.len);
    const r = probe.hits[0].rect;
    const point: [2]f32 = .{ r.x + r.w / 2, r.y + r.h / 2 };

    // one click, then twenty thousand timeouts. Nothing else can deliver
    // `done`, so if it lands it came through the loop's drain.
    const events = [_]elmz.Event{ .{ .pointer_down = point }, .{ .pointer_up = point } };
    var fake: Fake = .{ .events = &events, .idle = 20_000 };

    const stats = try run(struct {}, CState, CMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 1), rt.state.clicks);
    try std.testing.expectEqual(@as(i32, 42), rt.state.got);
    try std.testing.expectEqual(@as(u32, 2), stats.messages);
}

// Two adjacent buttons; tView has only one, and this test needs a neighbour
// to misroute into.
fn pairView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    // TMsg has a single member, so both buttons dispatch `inc`. That is
    // enough: the question is whether a message is produced at all, not which
    // one -- under capture, zero messages is the only correct answer.
    const r = ui.row(.{ .children = &.{ ui.button(.{ .label = "-", .msg = .inc }), ui.button(.{ .label = "+", .msg = .inc }) }, .gap = 10 });
    return r;
}

// The bug pointer capture exists to kill: two adjacent buttons, a press on
// one and a release on the other. Hit-testing the release point alone would
// dispatch the neighbour.
test "a press on one button released over another dispatches nothing" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, pairView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 2), probe.hits.len);
    const minus = probe.hits[0].rect;
    const plus = probe.hits[1].rect;

    const events = [_]elmz.Event{
        .{ .pointer_down = .{ minus.x + 2, minus.y + 2 } },
        .{ .pointer_up = .{ plus.x + 2, plus.y + 2 } },
        .quit,
    };
    var fake: Fake = .{ .events = &events };

    const stats = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(i32, 0), rt.state.n);
    try std.testing.expectEqual(@as(u32, 0), stats.messages);
    // Three: the initial paint, plus one for the press lighting up and one
    // for the release clearing it. Neither is a message repaint.
    try std.testing.expectEqual(@as(u32, 3), stats.frames);
}

test "only the region that owns the press stays lit" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, pairView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 2), probe.hits.len);
    const a = probe.hits[0].rect;
    const b = probe.hits[1].rect;
    const pa: [2]f32 = .{ a.x + a.w / 2, a.y + a.h / 2 };
    const pb: [2]f32 = .{ b.x + b.w / 2, b.y + b.h / 2 };

    // sample a corner well clear of the glyphs, which sit in the middle
    const sample_a = [2]f32{ a.x + 4, a.y + 4 };
    const sample_b = [2]f32{ b.x + 4, b.y + 4 };

    // hover over A
    rt.pointer = .{ .pos = pa };
    try repaint(&rt, &canvas);
    try expectPixel(&canvas, sample_a, rt.ui.theme.hover);
    try expectPixel(&canvas, sample_b, rt.ui.theme.control);

    // a press owned by A while the cursor sits over B: A keeps the pressed
    // colour and B is NOT hovered, even though the pointer is on top of it.
    // The claim is taken through the real hit test, not forged.
    rt.pointer = .{ .pos = pb };
    rt.press.down(&probe, pa);
    try repaint(&rt, &canvas);
    try expectPixel(&canvas, sample_a, rt.ui.theme.pressed);
    try expectPixel(&canvas, sample_b, rt.ui.theme.control);
}

// ---------------------------------------------------------------------------
// identity, not overlap
// ---------------------------------------------------------------------------

/// A card that reacts to the pointer, with a button inside it. Built to catch
/// the difference between "contains the pointer" and "is what the pointer is
/// on": the card overlaps every pixel of its button.
fn cardView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const b = ui.button(.{ .label = "x", .msg = .inc, .width = 60 });

    const card = ui.column(.{ .children = &.{
        b,
    }, .width = 200, .hover_bg = .{ .solid = ui.theme.hover }, .press_bg = .{ .solid = ui.theme.pressed }, .style = .{ .pad = 20, .bg = ui.theme.control } });
    return card;
}

test "hover lights the innermost region, not the container behind it" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, cardView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.hits.len);
    const btn = probe.hits[0].rect;
    // clear of the glyph, which sits in the middle of the button
    const on_btn = [2]f32{ btn.x + 4, btn.y + 4 };
    // inside the card, outside the button: the card's own padding
    const on_pad = [2]f32{ 5, 5 };

    // pointer on the button: the button lights, the card behind it stays cold
    rt.pointer = .{ .pos = on_btn };
    try repaint(&rt, &canvas);
    try expectPixel(&canvas, on_btn, rt.ui.theme.hover);
    try expectPixel(&canvas, on_pad, rt.ui.theme.control);

    // pointer on the card's padding: now the card is what is being hovered
    rt.pointer = .{ .pos = on_pad };
    try repaint(&rt, &canvas);
    try expectPixel(&canvas, on_pad, rt.ui.theme.hover);
}

test "pressing the button does not press its container" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, cardView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    const btn = probe.hits[0].rect;
    const on_btn = [2]f32{ btn.x + 4, btn.y + 4 };
    const on_pad = [2]f32{ 5, 5 };

    rt.pointer = .{ .pos = on_btn };
    rt.press.down(&probe, on_btn);
    try repaint(&rt, &canvas);

    try expectPixel(&canvas, on_btn, rt.ui.theme.pressed);
    // the card overlaps the button entirely, and must still be cold
    try expectPixel(&canvas, on_pad, rt.ui.theme.control);
}

test "a cancelled press fires nothing and leaves nothing lit" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, cardView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    const btn = probe.hits[0].rect;
    const on_btn = [2]f32{ btn.x + btn.w / 2, btn.y + btn.h / 2 };

    // down, then the platform takes the gesture away, then a release arrives
    // anyway: nothing should fire, because the claim is already gone.
    const events = [_]elmz.Event{
        .{ .pointer_down = on_btn },
        .pointer_cancel,
        .{ .pointer_up = on_btn },
        .quit,
    };
    var fake: Fake = .{ .events = &events };
    const stats = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(i32, 0), rt.state.n);
    try std.testing.expectEqual(@as(u32, 0), stats.messages);

    // The claim is gone, so the button is not *pressed* -- but that trailing
    // release still reports where the cursor is, so it is hovered. The pair is
    // the assertion: the press tint was dropped without losing the position.
    var after = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer after.deinit();
    canvas.clear(rt.ui.theme.panel);
    canvas.paintFrame(after.prims);
    try expectPixel(&canvas, .{ btn.x + 4, btn.y + 4 }, rt.ui.theme.hover);
}

fn repaint(rt: *elmz.Runtime(TState, TMsg), canvas: *software.Canvas) !void {
    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();
    canvas.clear(rt.ui.theme.panel);
    canvas.paintFrame(f.prims);
}

fn expectPixel(canvas: *software.Canvas, p: [2]f32, want: elmz.Color) !void {
    const x: usize = @intFromFloat(p[0]);
    const y: usize = @intFromFloat(p[1]);
    const i = (y * canvas.w + x) * 4;
    const got: elmz.Color = .{ .r = canvas.px[i], .g = canvas.px[i + 1], .b = canvas.px[i + 2], .a = canvas.px[i + 3] };
    try std.testing.expectEqual(want.r, got.r);
    try std.testing.expectEqual(want.g, got.g);
    try std.testing.expectEqual(want.b, got.b);
}

test "a release with no press before it dispatches nothing" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer probe.deinit();
    const r = probe.hits[0].rect;
    const point: [2]f32 = .{ r.x + r.w / 2, r.y + r.h / 2 };

    const events = [_]elmz.Event{ .{ .pointer_up = point }, .quit };
    var fake: Fake = .{ .events = &events };

    const stats = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(i32, 0), rt.state.n);
    try std.testing.expectEqual(@as(u32, 0), stats.messages);
}

test "the same event script produces the same frames and the same pixels" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    const point: [2]f32 = .{ 100, 60 };
    const events = [_]elmz.Event{
        .{ .pointer_down = point },
        .{ .pointer_up = point },
        .quit,
    };

    var results: [2]struct { frames: u32, messages: u32, hash: u64 } = undefined;
    for (&results) |*res| {
        var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
        defer rt.deinit();

        var fake: Fake = .{ .events = &events };
        const stats = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });
        res.* = .{ .frames = stats.frames, .messages = stats.messages, .hash = fake.last_hash };
    }

    try std.testing.expectEqual(results[0].frames, results[1].frames);
    try std.testing.expectEqual(results[0].messages, results[1].messages);
    try std.testing.expectEqual(results[0].hash, results[1].hash);
}

// phase 3: wrapped text through the real layout path. The paragraph is given
// no width of its own: the column is 120 wide and layout passes that down, so
// this also covers measure() taking the width it is measured into.
fn wrapped(ui: *elmz.Ui(TMsg), bytes: []const u8) *elmz.Element(TMsg) {
    const e = ui.text(.{ .label = bytes, .size = 12, .wrap = true });
    return e;
}

fn pView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const inner = ui.column(.{ .children = &.{
        wrapped(ui, "the quick brown fox jumps over the lazy dog and keeps going"),
    }, .width = 120 });
    return inner;
}

test "a paragraph wraps to its width and paints one prim per line" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 300, 300);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, pView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 300, .h = 300 }, canvas.renderer());
    defer f.deinit();

    var ys: [elmz.max_lines]f32 = undefined;
    var n: usize = 0;
    for (f.prims) |p| switch (p) {
        .text => |t| {
            if (n < ys.len) {
                ys[n] = t.y;
                n += 1;
            }
        },
        else => {},
    };
    try std.testing.expect(n >= 2); // it really broke into lines

    // consecutive lines are exactly one line-height apart
    const m = software.Canvas.measureText(
        "the quick brown fox jumps over the lazy dog and keeps going",
        12,
    );
    var i: usize = 1;
    while (i < n) : (i += 1) {
        try std.testing.expectApproxEqAbs(m.line_height, ys[i] - ys[i - 1], 0.01);
    }
}

// ---------------------------------------------------------------------------
// clip: containment, pruning, and presses outside the window
// ---------------------------------------------------------------------------

/// A 120x80 box that clips, holding content deliberately larger than it: two
/// bands that are partly visible (600 wide in a 120 box) and one entirely
/// below the bottom edge.
fn clipView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const a = ui.rect(.{ .width = 600, .height = 60, .style = .{ .bg = ui.theme.accent } });
    const b = ui.rect(.{ .width = 600, .height = 20, .style = .{ .bg = ui.theme.accent } });
    const c = ui.rect(.{ .width = 600, .height = 20, .style = .{ .bg = ui.theme.accent } }); // starts at y = 90, wholly outside
    const box = ui.column(.{ .children = &.{ a, b, ui.spaceBefore(c, 10) }, .width = 120, .height = 80 });
    box.clips = true;
    // nested, so the box is painted at the size it measured
    return ui.column(.{ .children = &.{box} });
}

test "a clipping container confines every primitive to its own box" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, clipView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();

    const box: elmz.Rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };

    var saw_quad = false;
    for (f.prims) |p| {
        // the clip recorded on a primitive is what it will be cut to, so it
        // must never be larger than the container that asked for it
        const c = p.clipOf();
        try std.testing.expect(c.x >= box.x - 0.01 and c.y >= box.y - 0.01);
        try std.testing.expect(c.x + c.w <= box.x + box.w + 0.01);
        try std.testing.expect(c.y + c.h <= box.y + box.h + 0.01);

        // and no primitive may sit entirely outside, whatever its rect says
        switch (p) {
            // Except a halo: reaching outside the element is the feature.
            .halo => {},
            .quad => |q| {
                saw_quad = true;
                try std.testing.expect(!q.rect.intersect(c).isEmpty());
            },
            .rrect => |q| try std.testing.expect(!q.rect.intersect(c).isEmpty()),
            .text => |t| try std.testing.expect(t.y <= box.y + box.h),
        }
    }
    try std.testing.expect(saw_quad);

    // the band at y = 90..110 is wholly clipped, so it is pruned rather than
    // emitted and left for the rasteriser to reject
    for (f.prims) |p| switch (p) {
        .quad => |q| try std.testing.expect(!(q.rect.y >= 80 and q.rect.y < 90)),
        else => {},
    };

    canvas.paintFrame(f.prims);
    for (0..canvas.h) |y| {
        for (0..canvas.w) |x| {
            if (y >= 80) {
                const i = (y * canvas.w + x) * 4;
                try std.testing.expectEqual(@as(u8, 0), canvas.px[i + 3]);
            }
        }
    }
}

/// A button 32 tall in a box only 16 tall: its lower half is outside the clip.
fn clipHitView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const box = ui.column(.{ .children = &.{ui.button(.{ .label = "inc", .msg = .inc })}, .width = 120, .height = 16 });
    box.clips = true;
    return ui.column(.{ .children = &.{box} });
}

test "a press outside a clipping container is not a hit" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, clipHitView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();

    try std.testing.expectEqual(@as(usize, 1), f.hits.len);
    const r = f.hits[0].rect;
    try std.testing.expect(r.h > 16); // the button really does stick out

    // inside both the button and the visible band
    try std.testing.expectEqual(TMsg.inc, f.hitTest(.{ r.x + r.w / 2, 8 }).?);
    // inside the button, outside the band it is clipped to
    try std.testing.expectEqual(@as(?TMsg, null), f.hitTest(.{ r.x + r.w / 2, 24 }));
}

fn noopClipOff(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const blk = ui.rect(.{ .width = 40, .height = 10, .style = .{ .bg = ui.theme.accent } });
    const box = ui.column(.{ .children = &.{ ui.text(.{ .label = "fits", .size = 12 }), blk }, .width = 120, .height = 60, .style = .{ .bg = ui.theme.panel } });
    return ui.column(.{ .children = &.{box} });
}

fn noopClipOn(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    const w = noopClipOff(s, ui);
    w.clips = true;
    return w;
}

test "clipping that does not bind changes nothing on screen" {
    const gpa = std.testing.allocator;

    const views = [_]*const fn (*TState, *elmz.Ui(TMsg)) *elmz.Element(TMsg){
        noopClipOff,
        noopClipOn,
    };
    var hashes: [2]u64 = undefined;
    var counts: [2]usize = undefined;

    for (views, 0..) |view, i| {
        var canvas = try software.Canvas.init(gpa, 200, 120);
        defer canvas.deinit();
        var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, view);
        defer rt.deinit();

        var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
        defer f.deinit();

        canvas.paintFrame(f.prims);
        counts[i] = f.prims.len;
        hashes[i] = std.hash.Wyhash.hash(0, canvas.px);
    }

    try std.testing.expectEqual(counts[0], counts[1]);
    try std.testing.expectEqual(hashes[0], hashes[1]);
}

// ---------------------------------------------------------------------------
// measure: the width comes from layout, not from the call site
// ---------------------------------------------------------------------------

fn paraNarrow(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const c = ui.column(.{ .children = &.{wrapped(ui, "the quick brown fox jumps over the lazy dog and keeps going")}, .width = 100 });
    return c;
}

fn paraWide(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    _ = s;
    const c = ui.column(.{ .children = &.{wrapped(ui, "the quick brown fox jumps over the lazy dog and keeps going")}, .width = 400 });
    return c;
}

test "a paragraph takes the width layout gives it, and never exceeds it" {
    const gpa = std.testing.allocator;
    const views = [_]*const fn (*TState, *elmz.Ui(TMsg)) *elmz.Element(TMsg){
        paraNarrow,
        paraWide,
    };
    var lines: [2]usize = undefined;

    for (views, 0..) |view, i| {
        var canvas = try software.Canvas.init(gpa, 500, 300);
        defer canvas.deinit();
        var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, view);
        defer rt.deinit();

        var f = try rt.frame(.{ .w = 500, .h = 300 }, canvas.renderer());
        defer f.deinit();

        const limit: f32 = if (i == 0) 100 else 400;
        var n: usize = 0;
        for (f.prims) |p| switch (p) {
            .text => |t| {
                n += 1;
                const m = software.Canvas.measureText(t.bytes, t.size);
                try std.testing.expect(m.width <= limit + 0.01);
            },
            else => {},
        };
        lines[i] = n;
    }

    // the narrower column wraps more, which is the width having come from
    // layout rather than from a numwritten at the call site
    try std.testing.expect(lines[0] > lines[1]);
}

// ---------------------------------------------------------------------------
// Primitive-count pins.
//
// These exist because a real bug got through every other test in this file: the
// background of a button was painted twice (once by the generic fill block,
// once by the `button` arm), so every example silently gained one prim per
// button. Nothing failed -- the suite was green, the pixels looked fine, only
// the counts moved. Counting is the cheapest assertion that a paint change did
// exactly one thing.
// ---------------------------------------------------------------------------

fn oneButtonView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    return ui.button(.{ .label = "x", .msg = .inc });
}

fn oneBarView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    return ui.bar(.{ .value = 0.5 });
}

test "a button paints exactly one fill and one label" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, oneButtonView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();

    var quads: usize = 0;
    var texts: usize = 0;
    for (f.prims) |p| switch (p) {
        .quad, .rrect => quads += 1,
        .text => texts += 1,
        .halo => {},
    };
    // One fill, one label. Two quads means something upstream is drawing the
    // same rect twice, which is invisible on screen and wrong everywhere else.
    try std.testing.expectEqual(@as(usize, 1), quads);
    try std.testing.expectEqual(@as(usize, 1), texts);
    try std.testing.expectEqual(@as(usize, 2), f.prims.len);
}

test "a bar paints a track and a value fill, and nothing twice" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, oneBarView);
    defer rt.deinit();

    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();

    var quads: usize = 0;
    for (f.prims) |p| switch (p) {
        .quad, .rrect => quads += 1,
        .text => {},
        .halo => {},
    };
    try std.testing.expectEqual(@as(usize, 2), quads);
    try std.testing.expectEqual(@as(usize, 2), f.prims.len);

    // The two fills must differ: a value fill painted over the whole track
    // would mean the clamp or the width maths ate the fraction.
    const a = f.prims[0].quad.rect;
    const b = f.prims[1].quad.rect;
    try std.testing.expect(a.w > b.w);
    try std.testing.expectEqual(a.x, b.x);
}

fn bgView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    const r = ui.rect(.{ .width = 40, .height = 20, .style = .{ .bg = ui.theme.panel } });
    return r;
}

fn borderView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    const r = ui.rect(.{ .width = 40, .height = 20, .style = .{ .border = ui.theme.accent } });
    return r;
}

fn bgAndBorderView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    const r = ui.rect(.{ .width = 40, .height = 20, .style = .{ .bg = ui.theme.panel, .border = ui.theme.accent } });
    return r;
}

fn primsOf(gpa: std.mem.Allocator, view: anytype, out: []elmz.Primitive) ![]const elmz.Primitive {
    var canvas = try software.Canvas.init(gpa, 120, 80);
    defer canvas.deinit();
    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, view);
    defer rt.deinit();
    var f = try rt.frame(.{ .w = 120, .h = 80 }, canvas.renderer());
    defer f.deinit();
    const n = @min(f.prims.len, out.len);
    @memcpy(out[0..n], f.prims[0..n]);
    return out[0..n];
}

test "bg, border, and both, each emit the number of prims they cost" {
    const gpa = std.testing.allocator;
    var buf: [8]elmz.Primitive = undefined;

    // A background is one quad. Anything more is the same rect painted twice.
    try std.testing.expectEqual(@as(usize, 1), (try primsOf(gpa, bgView, &buf)).len);

    // A border is four 1px quads: a frame, not a stroke primitive.
    const b = try primsOf(gpa, borderView, &buf);
    try std.testing.expectEqual(@as(usize, 4), b.len);

    // Together: 5. This is the one that catches a fill block and a kind arm
    // both drawing the background -- exactly the bug that made every button
    // emit one prim too many.
    try std.testing.expectEqual(@as(usize, 5), (try primsOf(gpa, bgAndBorderView, &buf)).len);
}

test "the loop never blocks forever while a theme file is being watched" {
    // Nothing watched: an app is allowed to sleep until input, as before.
    try std.testing.expectEqual(@as(i32, -1), effectiveTimeout(.{}, false, false));
    // Watched: bounded, or an edit waits for the pointer to enter the window.
    try std.testing.expectEqual(@as(i32, 250), effectiveTimeout(.{ .theme_path = "theme.zon" }, false, true));
    // A command in flight keeps its own tighter budget.
    try std.testing.expectEqual(@as(i32, 5), effectiveTimeout(.{ .theme_path = "theme.zon" }, true, true));
    // An app that already asked for less does not get slowed down.
    try std.testing.expectEqual(@as(i32, 30), effectiveTimeout(.{ .poll_timeout_ms = 30 }, false, true));
}

test "a relative theme path resolves beside the executable, not the cwd" {
    const exe = std.process.executablePathAlloc(std.testing.io, std.testing.allocator) catch
        return error.SkipZigTest;
    defer std.testing.allocator.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return error.SkipZigTest;
    const got = themePathBesideExe(std.testing.allocator, std.testing.io, "theme.zon") orelse
        return error.SkipZigTest;
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.fs.path.isAbsolute(got));
    try std.testing.expectEqualStrings(dir, std.fs.path.dirname(got).?);
    try std.testing.expectEqualStrings("theme.zon", std.fs.path.basename(got));
}

// ---------------------------------------------------------------------------
// the theme chain: defaults.zon under theme.zon, both live on disk
// ---------------------------------------------------------------------------

/// A `tmpDir` path in the cwd-relative form the binary under test runs in.
fn tmpPath(buf: []u8, dir: std.testing.TmpDir, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/{s}", .{ dir.sub_path, name });
}

test "the chain layers the override over the developer's base" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.defaults.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .bg = 0x102030, .panel = 0x203040 } } }",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0xabcdef } } }",
    });

    var bb: [128]u8 = undefined;
    var ub: [128]u8 = undefined;
    const base = try tmpPath(&bb, tmp, "theme.defaults.zon");
    const user = try tmpPath(&ub, tmp, "theme.zon");

    const chain = resolveChain(struct {}, gpa, io, .{}, base, user);
    try std.testing.expect(chain.base_from_file);
    try std.testing.expect(chain.user_from_file);
    try std.testing.expectEqual(@as(?[]const u8, null), chain.message());

    // The base supplied the page colours...
    try std.testing.expect(std.meta.eql(chain.theme.bg, elmz.Color.rgbHex(0x102030)));
    try std.testing.expect(std.meta.eql(chain.theme.panel, elmz.Color.rgbHex(0x203040)));
    // ...the override replaced exactly one role...
    try std.testing.expect(std.meta.eql(chain.theme.accent, elmz.Color.rgbHex(0xabcdef)));
    // ...and inherited the rest from the base, not from the compiled floor.
    try std.testing.expect(!std.meta.eql(chain.theme.panel, (elmz.Theme{}).panel));
}

test "a defaults file that will not load keeps the floor and says so" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "theme.defaults.zon", .data = "this is not zon" });

    var bb: [128]u8 = undefined;
    const base = try tmpPath(&bb, tmp, "theme.defaults.zon");

    const chain = resolveChain(struct {}, gpa, io, .{}, base, null);
    try std.testing.expect(chain.base_rejected);
    try std.testing.expect(!chain.base_from_file);
    try std.testing.expect(std.meta.eql(chain.theme, elmz.Theme{}));
    // The band has to name the file: a bare parse error does not tell the reader
    // which of the two theme files to open.
    try std.testing.expect(std.mem.find(u8, chain.message().?, "theme.defaults.zon") != null);
}

test "a file that is not there is not an error in the chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var bb: [128]u8 = undefined;
    var ub: [128]u8 = undefined;
    const base = try tmpPath(&bb, tmp, "theme.defaults.zon");
    const user = try tmpPath(&ub, tmp, "theme.zon");

    const chain = resolveChain(struct {}, gpa, io, .{}, base, user);
    try std.testing.expect(!chain.base_rejected);
    try std.testing.expect(!chain.user_rejected);
    try std.testing.expectEqual(@as(?[]const u8, null), chain.message());
    try std.testing.expect(std.meta.eql(chain.theme, elmz.Theme{}));
}

test "a file that disappears does not earn a reload" {
    const s: ThemeWatch.Stamp = .{ .mtime = 5, .size = 10 };
    // Absent now: an editor's save unlinks before it renames, and reverting the
    // palette mid-save would flash the fallback colours at the worst moment.
    try std.testing.expect(!ThemeWatch.shouldReload(true, s, null));
    // Present and different: reload.
    try std.testing.expect(ThemeWatch.shouldReload(true, s, .{ .mtime = 6, .size = 10 }));
    try std.testing.expect(ThemeWatch.shouldReload(true, s, .{ .mtime = 5, .size = 11 }));
    // Present and identical: nothing to do.
    try std.testing.expect(!ThemeWatch.shouldReload(true, s, s));
    // Never seen before, and it is there: load it.
    try std.testing.expect(ThemeWatch.shouldReload(false, null, s));
    // Never seen, still absent: nothing to do.
    try std.testing.expect(!ThemeWatch.shouldReload(false, null, null));
}

test "editing the base re-applies the override on top of it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.defaults.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .bg = 0x102030 } } }",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0xabcdef } } }",
    });

    var bb: [128]u8 = undefined;
    var ub: [128]u8 = undefined;
    const base = try tmpPath(&bb, tmp, "theme.defaults.zon");
    const user = try tmpPath(&ub, tmp, "theme.zon");

    var ui = elmz.Ui(u8).init(gpa);
    defer ui.deinit();

    var watch = ThemeWatch.init(.{}, base, user);
    watch.poll(&ui, io, gpa);
    try std.testing.expect(std.meta.eql(ui.theme.bg, elmz.Color.rgbHex(0x102030)));
    try std.testing.expect(std.meta.eql(ui.theme.accent, elmz.Color.rgbHex(0xabcdef)));

    // The developer edits the base. This is the case a single-stamp watch gets
    // wrong: reloading the base alone would leave the override resolved against
    // a palette that no longer exists.
    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.defaults.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .bg = 0x405060, .panel = 0x203040 } } }",
    });

    watch.poll(&ui, io, gpa);
    try std.testing.expect(std.meta.eql(ui.theme.bg, elmz.Color.rgbHex(0x405060)));
    try std.testing.expect(std.meta.eql(ui.theme.accent, elmz.Color.rgbHex(0xabcdef)));

    // An unchanged pass touches nothing.
    const settled = ui.theme;
    watch.poll(&ui, io, gpa);
    try std.testing.expect(std.meta.eql(settled, ui.theme));
}

test "the app tier is parsed against the type the app declares, and refused without one" {
    // The bug this closes: `resolveChain` hardcoded `struct {}`, so an app that
    // declared tokens had its `.app` section rejected by the very function that
    // loads it -- the tier worked when called directly and never through the
    // runner. Same file, two callers, opposite answers.
    const Tokens = struct { sidebar_width: u16 = 200 };

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0x89b4fa } }, .app = .{ .sidebar_width = 240 } }",
    });
    var bb: [128]u8 = undefined;
    var ub: [128]u8 = undefined;
    const base = try tmpPath(&bb, tmp, "theme.defaults.zon");
    const user = try tmpPath(&ub, tmp, "theme.zon");

    // Declared: the value arrives, typed.
    const declared = resolveChain(Tokens, gpa, io, .{}, base, user);
    try std.testing.expect(declared.user_from_file);
    try std.testing.expectEqual(@as(u16, 240), declared.app.sidebar_width);
    try std.testing.expect(declared.message() == null);

    // Undeclared: rejected, with the offending key named rather than swallowed.
    const undeclared = resolveChain(struct {}, gpa, io, .{}, base, user);
    try std.testing.expect(undeclared.user_rejected);
    try std.testing.expect(undeclared.message() != null);
    try std.testing.expect(std.mem.indexOf(u8, undeclared.diag.text(), "sidebar_width") != null);
}

test "a gradient written into the file reaches the Ui, and leaves when edited out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Colours and gradients are separate questions, so this is the seam that
    // would otherwise be dead: `Ui.gradients` is only worth having if a poll
    // actually fills it.
    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0x89b4fa }, .gradients = .{ .accent = .{ .linear = .{ .dir = 45, .from = 0x89b4fa, .to = 0xf5c2e7 } } } } }",
    });

    var bb: [128]u8 = undefined;
    var ub: [128]u8 = undefined;
    // No base file: the compiled floor is enough, and this isolates the override.
    var watch = ThemeWatch.init(.{}, try tmpPath(&bb, tmp, "theme.defaults.zon"), try tmpPath(&ub, tmp, "theme.zon"));

    var ui = elmz.Ui(u8).init(gpa);
    defer ui.deinit();

    watch.poll(&ui, io, gpa);
    const g = ui.gradients.accent orelse return error.GradientMissing;
    try std.testing.expectEqual(elmz.Fill.linear, std.meta.activeTag(g));
    // Colours still load alongside it -- the two halves are not exclusive.
    try std.testing.expect(std.meta.eql(ui.theme.accent, elmz.Color.rgbHex(0x89b4fa)));

    // Drop the gradient but keep the colour: the Ui must follow, or a stale
    // gradient would outlive the line that declared it.
    try tmp.dir.writeFile(io, .{
        .sub_path = "theme.zon",
        .data = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0x89b4fa } } }",
    });
    watch.poll(&ui, io, gpa);
    try std.testing.expect(ui.gradients.accent == null);
    try std.testing.expect(std.meta.eql(ui.theme.accent, elmz.Color.rgbHex(0x89b4fa)));
}

test "the frame ring averages painted frames and drops the oldest" {
    var r: FrameRing = .{};
    try std.testing.expectEqual(@as(u64, 0), r.meanNs());
    try std.testing.expectEqual(@as(f64, 0), r.fps());
    r.push(1_000_000);
    r.push(3_000_000);
    try std.testing.expectEqual(@as(u64, 2_000_000), r.meanNs());
    try std.testing.expectApproxEqAbs(@as(f64, 500), r.fps(), 0.001);

    var i: usize = 0;
    while (i < FrameRing.capacity) : (i += 1) r.push(4_000_000);
    try std.testing.expectEqual(FrameRing.capacity, r.len);
    try std.testing.expectEqual(@as(u64, 4_000_000), r.meanNs());
}

test "the overlay paints inside its panel and nowhere else" {
    var c = try software.Canvas.init(std.testing.allocator, 260, 120);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    drawOverlay(&c, .{
        .frame_ns = 850_000,
        .build_ns = 50_000,
        .paint_ns = 800_000,
        .mean_ns = 900_000,
        .prims = 80,
        .hits = 5,
    });

    var painted: usize = 0;
    var outside: usize = 0;
    var corner: usize = 0;
    var y: u32 = 0;
    while (y < c.h) : (y += 1) {
        var x: u32 = 0;
        while (x < c.w) : (x += 1) {
            const i = (@as(usize, y) * c.w + x) * 4;
            if (c.px[i] != 0 or c.px[i + 1] != 0 or c.px[i + 2] != 0) {
                painted += 1;
                // Four 13px lines from (3,3): the readout ended up far from
                // the corner it is wedged into, or it escaped onto pixels it
                // has no business touching.
                if (x > 210 or y > 60) outside += 1;
                if (x < 24 and y < 16) corner += 1;
            }
        }
    }
    try std.testing.expect(painted > 500);
    try std.testing.expectEqual(@as(usize, 0), outside);
    // It is wedged in the corner rather than merely near it.
    try std.testing.expect(corner > 40);
}
