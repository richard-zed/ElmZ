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
    ns: [capacity]u64 = @splat(0),
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
    const edge = elmz.Color{ .r = 0xa6, .g = 0xad, .b = 0xc8, .a = 255 };

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
        canvas.drawText(pad, y, size, .{ .solid = if (i == 0) fg else edge }, line);
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
    /// Monotonic NANOSECONDS for the frame clock, injected. A headless run has
    /// no io and a windowed one has no reason to be reproducible, but an
    /// animation whose dt cannot be chosen cannot be tested at all -- so the
    /// source is a parameter, not a global.
    now_ns: ?*const fn () u64 = null,
    /// Longest one poll may block while the app is animating. The loop
    /// measures real elapsed time, so this bounds how stale a frame can get;
    /// it is not a frame rate.
    anim_poll_ms: i32 = 8,

    /// How long the loop may block while a toast is on screen. Same trap as the
    /// animation clock and the theme watcher: `poll_timeout_ms` defaults to -1,
    /// so without this a toast would sit there until the pointer moved.
    toast_poll_ms: i32 = 100,
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
        font_buf: [elmz.font_name_max]u8 = undefined,
        font_len: usize = 0,

        pub const Stamp = struct { mtime: i128 = 0, size: u64 = 0 };

        /// The typeface the chain last named, or null when no file names one.
        pub fn fontName(self: *const Self) ?[]const u8 {
            return if (self.font_len == 0) null else self.font_buf[0..self.font_len];
        }

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
            // Kept, not applied: the watch has no canvas. The loop reads this
            // and swaps the face, so resolution still happens in exactly one
            // place (here) and attachment in exactly one place (the caller).
            if (chain.fontName()) |f| {
                @memcpy(self.font_buf[0..f.len], f);
                self.font_len = f.len;
            } else self.font_len = 0;
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
        /// The typeface the chain names, COPIED: the files were read into
        /// buffers that die before this is returned. Empty means no file named
        /// one, which is not a fault -- it means keep whatever is attached.
        font_buf: [elmz.font_name_max]u8 = undefined,
        font_len: usize = 0,
        /// A `theme.defaults.zon` supplied the base rather than the compiled floor.
        base_from_file: bool = false,
        /// The defaults file was there and would not load; `diag` says why.
        base_rejected: bool = false,
        /// A `theme.zon` supplied the override.
        user_from_file: bool = false,
        /// The override was there and would not load; `diag` says why.
        user_rejected: bool = false,
        diag: elmz.ThemeDiag = .{},

        /// The typeface the chain names, or null when no file names one.
        pub fn fontName(self: *const @This()) ?[]const u8 {
            return if (self.font_len == 0) null else self.font_buf[0..self.font_len];
        }

        /// The one line the band should show, or null when nothing went wrong.
        pub fn message(self: *const @This()) ?[]const u8 {
            if (self.base_rejected or self.user_rejected) return self.diag.text();
            return null;
        }
    };
}

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
                if (loaded.fontName()) |f| {
                    @memcpy(out.font_buf[0..f.len], f);
                    out.font_len = f.len;
                }
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
                // The end user's name wins outright, and an override that omits
                // `.font` inherits the developer's -- the same rule the colours
                // follow, so one file cannot mean two things.
                if (loaded.fontName()) |f| {
                    @memcpy(out.font_buf[0..f.len], f);
                    out.font_len = f.len;
                }
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
fn effectiveTimeout(opts: Options, busy: bool, watching: bool, animating: bool, toasting: bool) i32 {
    if (busy) return 5;
    // An animation produces frames with no input at all, so blocking here is
    // exactly the bug: it would freeze until the pointer moved.
    if (animating) return opts.anim_poll_ms;
    // A toast expires on a wall clock with no input to wake the loop, so the
    // wait is bounded whether or not anything else is moving.
    if (toasting) return if (opts.poll_timeout_ms < 0) opts.toast_poll_ms else @min(opts.poll_timeout_ms, opts.toast_poll_ms);
    if (!watching) return opts.poll_timeout_ms;
    if (opts.poll_timeout_ms < 0) return opts.theme_poll_ms;
    return @min(opts.poll_timeout_ms, opts.theme_poll_ms);
}

/// A logical size as a pixel count. Ceiling rather than truncation, because a
/// fractional box that rounds DOWN loses its last partial pixel column, and the
/// backend rounds the same value for its texture -- if the two disagree by one
/// the frame is resampled by a hair, which is exactly the kind of softness that
/// gets blamed on HiDPI.
fn pixelDim(v: f32) u32 {
    if (!(v >= 1)) return 0;
    return @intFromFloat(@ceil(v));
}

/// Monotonic nanoseconds: the injected source when there is one, else the io
/// clock, else zero (no io, no clock, no dt -- and no animation without io).
fn clockNs(opts: Options, io: ?std.Io) u64 {
    if (opts.now_ns) |f| return f();
    if (io) |i| {
        const ns = std.Io.Timestamp.now(i, .awake).toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }
    return 0;
}

pub const Stats = struct {
    frames: u32 = 0,
    events: u32 = 0,
    messages: u32 = 0,
};

/// The face the chain asked for, and the bytes it was made from.
///
/// Bytes have an owner and the owner is here: a swapped face free's the previous
/// buffer rather than leaking it, and the whole slot frees on the way out. The
/// applied NAME is kept beside them so the loop can tell "same font, new frame"
/// from "the file changed its mind".
pub const FontSlot = struct {
    bytes: ?[]u8 = null,
    applied: [elmz.font_name_max]u8 = undefined,
    applied_len: usize = 0,
    canvas: ?*software.Canvas = null,

    pub fn deinit(self: *FontSlot, gpa: std.mem.Allocator) void {
        if (self.bytes) |b| gpa.free(b);
        self.bytes = null;
    }

    fn appliedName(self: *const FontSlot) []const u8 {
        return self.applied[0..self.applied_len];
    }
};

/// Attach the typeface the chain NAMED, if it names a different one than the
/// face already there. Returns whether anything changed, so the loop can mark
/// the frame dirty -- a font swap that does not repaint is a swap nobody sees.
///
/// Failure leaves the previous face attached and bands the name. That is the
/// entire rule: a font that cannot be found must never quietly become a
/// different font, because the render still looks deliberate.
pub fn applyChainFont(ui: anytype, gpa: std.mem.Allocator, io: std.Io, want: ?[]const u8, slot: *FontSlot) bool {
    const name = want orelse return false;
    if (std.mem.eql(u8, name, slot.appliedName())) return false;

    const bytes = software.loadFontByName(gpa, io, name, &.{}) catch {
        ui.failExternal(.font, "no font named {s}", .{name});
        return false;
    };
    slot.deinit(gpa);
    slot.bytes = bytes;
    @memcpy(slot.applied[0..name.len], name);
    slot.applied_len = name.len;
    if (slot.canvas) |cv| cv.setFont(bytes);
    return true;
}

/// Attach the typeface the theme chain NAMED, resolving the name to a file.
///
/// The name is the documented path: a `.zon` says "DejaVu Sans" and the library
/// finds the file, so the file may move without the theme knowing where fonts
/// live. Failure keeps whatever face is attached (nothing, at startup) and bands
/// with the NAME -- naming the file would be advice the author never wrote.
///
/// Substituting a different typeface on failure is the one outcome ruled out:
/// it renders, it looks deliberate, and nobody can tell it happened.
fn attachFontByName(ui: anytype, canvas: *software.Canvas, gpa: std.mem.Allocator, io: std.Io, name: []const u8) ?[]u8 {
    const bytes = software.loadFontByName(gpa, io, name, &.{}) catch {
        ui.failExternal(.font, "no font named {s}", .{name});
        return null;
    };
    canvas.setFont(bytes);
    return bytes;
}

/// Attach the app's declared typeface, or say why it is not there.
///
/// A path the app NAMED and the filesystem cannot produce is a fault: text
/// measures at zero, every text prim vanishes, and the window reads as a
/// renderer bug rather than a missing file. So it raises the band and keeps
/// running, same rule as the theme chain. An app that declares no `font_path`
/// never reaches here -- one font is a choice, a broken path is not.
///
/// The face stays attached on failure (`Font.none`), which is the honest
/// render: invisible text, not a crash and not a substituted typeface.
fn attachFont(ui: anytype, canvas: *software.Canvas, gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const bytes = software.loadFont(gpa, io, path) catch {
        // Both attempts are plain reads, so any failure means the app named a
        // typeface that cannot be produced from disk: absent, unreadable or a
        // directory. The band carries the path, because that is the one thing
        // the author can act on.
        ui.failExternal(.font, "cannot read font: {s}", .{path});
        return null;
    };
    canvas.setFont(bytes);
    return bytes;
}

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
    var font_bytes: ?[]u8 = null;
    defer if (font_bytes) |b| gpa.free(b);

    var rt = if (@hasField(@TypeOf(app), "state"))
        elmz.Runtime(S, M).init(gpa, app.state, app.update, app.view)
    else
        elmz.Runtime(S, M).init(gpa, .{}, app.update, app.view);
    defer rt.deinit();
    // A declared typeface loads once the runtime exists, so a path that cannot
    // be read can name itself in the error band instead of silently measuring
    // every glyph at zero.
    if (@hasField(@TypeOf(app), "font_path")) {
        if (io) |i| font_bytes = attachFont(&rt.ui, &canvas, gpa, i, app.font_path);
    }

    var opts: Options = .{ .io = io, .gpa = gpa, .overlay = default_overlay };
    // Keystrokes and typed text, same optional-field trick as `state`: an app
    // that declares `on_key` / `on_text` gets them, one that does not never
    // hears about them and pays nothing. Focus stays in the app's Model -- the
    // runtime has no focus ring, so it cannot pick a destination.
    if (@hasField(@TypeOf(app), "on_key")) rt.on_key = app.on_key;
    if (@hasField(@TypeOf(app), "on_text")) rt.on_text = app.on_text;
    if (@hasField(@TypeOf(app), "on_wheel")) rt.on_wheel = app.on_wheel;
    if (@hasField(@TypeOf(app), "on_outside")) rt.on_outside = app.on_outside;
    if (@hasField(@TypeOf(app), "on_tick")) rt.on_tick = app.on_tick;

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

/// What the runner keeps for as long as a gesture lasts. Kept here rather than
/// on `elmz.Drag`, which says what the ELEMENT is: a thumb needs the grab
/// offset and the offset at grab time, and a slider must never have either
/// (its value is where the pointer is). Generic over M only because a slider
/// has to dispatch its own message when the value moves.
fn ActiveDrag(comptime M: type) type {
    return union(enum) {
        /// A scroll thumb: tracked by grab offset, so the content does not jump
        /// to put the pointer in the middle of the thumb.
        thumb: struct {
            d: elmz.ScrollDrag,
            from_y: f32,
            from_off: f32,
        },
        /// A value control: tracked by ABSOLUTE position.
        slider: struct {
            d: elmz.SliderDrag,
            msg: M,
        },
    };
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
    // A shortcut collision is a BUILD error, not a race decided by whichever
    // arm was written first. Declared data can be checked before it ever runs,
    // so it is.
    if (@hasField(App, "shortcuts")) comptime elmz.checkShortcuts(App.shortcuts);

    var last_ns: u64 = clockNs(opts, opts.io);
    var running = true;

    // The claim lives in `rt.press`: one owner, so the colour shown while a
    // press is in flight cannot disagree with what dispatches on release.

    // Which region the pointer is over, as of the last frame. Motion only
    // earns a repaint when this changes; sweeping across empty space is free.
    var hovered: ?elmz.Rect = null;

    // A thumb drag in flight. The claim already lives in `rt.press`; this is
    // the extra bit a drag needs and a click does not: WHERE the grab started,
    // so moving the pointer can be read as a delta. Kept here rather than on
    // `Press` because a click never needs an origin, and the thumb is the only
    // control whose geometry moves out from under the pointer mid-gesture.
    var drag: ?ActiveDrag(M) = null;

    // A toast that is on screen, and how long it has been there. Runtime
    // transient like `hovered` and `drag`: the Model decides whether a toast
    // exists, this decides when it stops. A fixed-size array would silently
    // ignore the overflow, which is the failure this project keeps finding.
    const ToastSlot = struct {
        key: u64,
        t: f32,
        ttl: f32,
        msg: M,
        rect: elmz.Rect,
        seen: bool = true,
    };
    var toasts: std.ArrayListUnmanaged(ToastSlot) = .empty;
    defer toasts.deinit(rt.gpa);

    // messages produced by commands land here between polls
    var async_msgs: std.ArrayList(M) = .empty;
    defer async_msgs.deinit(rt.gpa);

    // Resolved once, against the executable's own directory, and owned for the
    // life of the loop. The watch holds the resolved paths; the copies are freed
    // on the way out.
    var base_owned: ?[:0]u8 = null;
    var user_owned: ?[:0]u8 = null;
    var theme_watch: ?ThemeWatchOf(App) = null;
    // The face the chain names, and the bytes behind it. Owned here so a swap
    // frees the previous buffer instead of leaking it.
    var font_slot: FontSlot = .{ .canvas = canvas };
    defer if (opts.gpa) |g| {
        if (base_owned) |p| g.free(p);
        if (user_owned) |p| g.free(p);
        font_slot.deinit(g);
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
                if (theme_watch) |*w| {
                    w.poll(&rt.ui, io_arg, g);
                    // Attached after the first resolve, so a theme naming a face
                    // gets it on frame one rather than after the first edit.
                    _ = applyChainFont(&rt.ui, g, io_arg, w.fontName(), &font_slot);
                }
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
                    // Same trigger as the palette: either file changing
                    // re-resolves the whole chain, and the font rides that. A
                    // swap must repaint or nobody sees it.
                    if (applyChainFont(&rt.ui, gpa_arg, io_arg, w.fontName(), &font_slot)) dirty = true;
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

            // Density is applied HERE and nowhere else above the renderer. Every
            // number the tree produced is logical -- layout, hit rects, the
            // pointer -- so the canvas is the one thing that has to be told how
            // many device pixels a logical unit is worth. A backend that answers
            // 0 (or garbage) falls back to 1 rather than blanking the canvas.
            const reported = window.density();
            const density: f32 = if (reported > 0) reported else 1;
            canvas.scale = density;

            // The frame is built for `size` and painted into this canvas, so the
            // two must be the same box. They were not: the canvas was allocated
            // once at startup, so after a resize the tree laid out at the new
            // size painted into the old buffer -- hit rects then disagreed with
            // the pixels under the cursor, which reads as "clicks land in the
            // wrong place" rather than as a resizing bug.
            try canvas.resize(
                pixelDim(size.w * density),
                pixelDim(size.h * density),
            );

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
            window.present(canvas.px, .{
                .w = @floatFromInt(canvas.w),
                .h = @floatFromInt(canvas.h),
            });

            stats.frames += 1;
            dirty = false;
            hovered = if (rt.pointer.pos) |p| blk: {
                break :blk if (frame.?.hit(p)) |h| h.rect else null;
            } else null;
        }

        // While a command is in flight, poll briefly instead of blocking
        // forever, or its result would sit in the queue until the next input.
        // Frame clock. Runs whether or not anything else happened: an
        // animation's entire point is to produce frames from nothing.
        const now_ns = clockNs(opts, opts.io);
        const dt_ns = now_ns -% last_ns;
        last_ns = now_ns;
        // Time for paint. Accumulated from the raw delta, capped only so a
        // pathological stall cannot overflow f32 precision in one step; the
        // clamp `on_tick` gets is deliberately NOT reused, because a blink
        // frozen by a stall is worse than one that jumped.
        const dt_secs: f32 = blk: {
            const raw: f32 = @floatFromInt(@min(dt_ns, std.time.ns_per_s));
            const secs = raw / std.time.ns_per_s;
            rt.elapsed += secs;
            rt.since_input += secs;
            rt.hover_since += secs;
            break :blk secs;
        };

        // Toast lifetimes. The Model owns whether a toast exists; the runtime
        // owns when it stops, because the clock it needs is the one thing
        // `view` cannot see and a per-app expiry timer is a timer everyone
        // rewrites.
        if (frame) |*f| {
            for (toasts.items) |*s| s.seen = false;
            for (f.hits) |h| {
                const key = h.key orelse continue;
                const w = h.widget orelse continue;
                const tst = switch (w.*) {
                    .toast => |t| t,
                    else => continue,
                };
                var slot: ?*ToastSlot = null;
                for (toasts.items) |*s| {
                    if (s.key == key) {
                        slot = s;
                        break;
                    }
                }
                if (slot) |sl| {
                    sl.rect = h.rect;
                    sl.seen = true;
                } else {
                    toasts.append(rt.gpa, .{
                        .key = key,
                        .t = 0,
                        .ttl = @as(f32, @floatFromInt(tst.ttl_ms)) / 1000,
                        .msg = tst.msg,
                        .rect = h.rect,
                    }) catch continue;
                    slot = &toasts.items[toasts.items.len - 1];
                }
                // Hover pauses the countdown: a toast that vanishes while you
                // are reading it is worse than one that lingers.
                const inside = if (rt.pointer.pos) |pt| slot.?.rect.containsRounded(0, pt) else false;
                if (!inside) slot.?.t += dt_secs;
            }
            // Absent from the frame means the app took it away; forget the slot
            // so the same key appearing later starts a fresh timer.
            var ti: usize = 0;
            while (ti < toasts.items.len) {
                const sl = toasts.items[ti];
                if (!sl.seen) {
                    _ = toasts.swapRemove(ti);
                    continue;
                }
                if (sl.t >= sl.ttl) {
                    const action = rt.dispatch(sl.msg);
                    stats.messages += 1;
                    if (action.quit) running = false;
                    dirty = dirty or action.repaint;
                    _ = toasts.swapRemove(ti);
                    continue;
                }
                ti += 1;
            }
        }
        // Outbound clipboard writes are applied by `dispatch`, which has no
        // other route to the platform. Assigned each iteration because a
        // Window is a two-field value: copying it is free and it cannot go
        // stale the way a cached pointer could.
        rt.window = window;

        if (rt.animate and rt.on_tick != null) {
            const secs: f32 = @floatFromInt(@min(dt_ns, std.time.ns_per_s));
            const dt: f32 = @min(secs / std.time.ns_per_s, 0.1);
            if (rt.on_tick.?(&rt.state, dt)) |msg| {
                const action = rt.dispatch(msg);
                stats.messages += 1;
                if (action.quit) running = false;
                dirty = dirty or action.repaint;
            }
        }

        const timeout = effectiveTimeout(opts, rt.asyncBusy(), theme_watch != null, rt.animate, toasts.items.len > 0);
        const ev = window.poll(timeout) orelse continue;
        stats.events += 1;

        // Any key or text event restarts the "typing" window, which is what a
        // blinking caret reads to stay solid while the user is working.
        switch (ev) {
            .key, .key_up, .text => rt.since_input = 0,
            else => {},
        }

        switch (ev) {
            .quit => {
                rt.press.cancel();
                running = false;
            },

            // The backend has already adopted the new size, so this only has to
            // ask for a frame; the dirty block reads the size back and resizes
            // the canvas before painting.
            .resize => dirty = true,

            // The press claims a region; the release only counts if it comes
            // back inside that same region. Hit-testing the release point
            // alone would let a press on one button dispatch its neighbour.
            .pointer_down => |p| {
                rt.pointer.pos = p;
                // The press owns its region from here until release, and the
                // renderer colours that region -- and only that one -- until
                // then, because it paints from this same claim.
                drag = null;
                if (frame) |*f| {
                    rt.press.down(f, p);
                    // A thumb is a region with no Msg, so the claim is the only
                    // thing that knows the press landed on one. The offset is
                    // read NOW, not tracked across frames: the grab is relative
                    // to where the thumb was when it was grabbed.
                    if (rt.press.captured) |h| {
                        if (h.drag) |d| switch (d) {
                            .thumb => |t| drag = .{ .thumb = .{
                                .d = t,
                                .from_y = p[1],
                                .from_off = rt.scrollOffset(t.key),
                            } },
                            .slider => |sl| {
                                // The message comes off the widget payload, not
                                // off the drag: the drag is geometry, and the
                                // payload is the only thing that knows what to
                                // dispatch. A slider with no payload could not
                                // report a change at all.
                                const msg: M = if (h.widget) |w| switch (w.*) {
                                    .slider => |pl| pl.msg,
                                    else => break,
                                } else break;
                                drag = .{ .slider = .{ .d = sl, .msg = msg } };
                                // A press moves the value NOW, so a click that
                                // never becomes a drag still does something: one
                                // step toward the pointer when stepped, exactly
                                // the pointer when continuous.
                                const next = if (sl.step == null)
                                    elmz.sliderValueAt(sl, p)
                                else
                                    elmz.sliderStepToward(sl, sl.value.*, p);
                                if (next != sl.value.*) {
                                    sl.value.* = next;
                                    const action = rt.dispatch(msg);
                                    stats.messages += 1;
                                    if (action.quit) running = false;
                                    dirty = dirty or action.repaint;
                                }
                            },
                        };
                    }
                    // Nothing under the pointer. Every claiming element is
                    // told about its own press through `Press`, so a press
                    // that claimed nothing is the one event no element can
                    // ever see -- and the one a popup needs in order to
                    // dismiss itself. Reported on the DOWN, not the release:
                    // dismissal that waits for the button to come up feels
                    // like the click was ignored.
                    else if (rt.on_outside) |hook| {
                        if (hook(&rt.state, p)) |msg| {
                            const action = rt.dispatch(msg);
                            stats.messages += 1;
                            if (action.quit) running = false;
                            dirty = dirty or action.repaint;
                        }
                    }
                } else rt.press.cancel();
                dirty = true;
            },

            .pointer_up => |p| {
                rt.pointer.pos = p;
                // A drag produces an offset, never a message: the thumb region
                // carries no Msg, so there is nothing to dispatch and nothing
                // to hit-test on release. Dropping the claim here is what stops
                // the thumb staying held after the button comes up.
                if (drag != null) {
                    drag = null;
                    rt.press.cancel();
                    dirty = true;
                    continue;
                }
                // Only a press that was actually CLAIMED can change paint: the
                // release drops that control's pressed look. A release over
                // empty space changes nothing, and marking dirty for it billed
                // a full frame to every stray click.
                dirty = dirty or rt.press.captured != null;
                if (rt.press.up(p)) |msg| {
                    const action = rt.dispatch(msg);
                    stats.messages += 1;
                    if (action.quit) running = false;
                    dirty = dirty or action.repaint;
                }
            },

            .pointer_move => |p| {
                rt.pointer.pos = p;
                // While a drag is in flight the pointer is moving the thumb,
                // not hovering anything: the thumb follows the cursor, so the
                // region under it is the region being dragged and re-running
                // hover would only mark a frame dirty that is already dirty.
                if (drag) |*held| switch (held.*) {
                    .thumb => |t| {
                        if (t.d.view.view_h > 0) {
                            // One unit of thumb travel is worth this much content.
                            const ratio = t.d.view.content_h / t.d.view.view_h;
                            const max_off = @max(0, t.d.view.content_h - t.d.view.view_h);
                            const next = std.math.clamp(t.from_off + (p[1] - t.from_y) * ratio, 0, max_off);
                            if (next != rt.scrollOffset(t.d.key)) {
                                rt.scrollTo(t.d.key, next);
                                dirty = true;
                            }
                        }
                    },
                    // A drag tracks the pointer and quantises as it goes: one
                    // step per motion event would lag a fast drag badly, which
                    // is why the click rule above is the only one-step path.
                    .slider => |*sl| {
                        const next = elmz.sliderValueAt(sl.d, p);
                        if (next != sl.d.value.*) {
                            sl.d.value.* = next;
                            const action = rt.dispatch(sl.msg);
                            stats.messages += 1;
                            if (action.quit) running = false;
                            dirty = dirty or action.repaint;
                        }
                    },
                } else if (frame) |*f| {
                    const now: ?elmz.Rect = if (f.hit(p)) |h| h.rect else null;
                    if (!sameRect(now, hovered)) {
                        hovered = now;
                        // The pointer arrived somewhere new, so the dwell
                        // clock starts again -- that is what makes a tooltip
                        // wait exactly once per target.
                        rt.hover_since = 0;
                        dirty = true;
                    }
                } else dirty = true;
            },

            // The release is not always going to arrive: focus can be taken
            // away, or the drag can leave the window. Dropping the claim here
            // is what stops a button staying lit for the rest of the session.
            .pointer_cancel => {
                rt.press.cancel();
                drag = null;
                rt.pointer.pos = null;
                hovered = null;
                dirty = true;
            },

            // Tab belongs to the RUNTIME, every other key to the app. Only the
            // frame knows the document order of the elements that can take
            // focus, so an app asked to traverse would be reimplementing layout
            // -- and it would get it wrong the moment anything wrapped.
            //
            // Everything else stays the app's call: a hook that returns null is
            // "not mine", and marking dirty unconditionally would bill a full
            // frame to every keypress nobody handled.
            .key => |k| tab: {
                if (k.named == .tab) {
                    if (frame) |*f| {
                        if (f.focusStep(rt.focus, !k.mods.shift)) |next| {
                            // The same key back means there was exactly one
                            // candidate. Handled, but nothing to repaint.
                            if (next != rt.focus) {
                                rt.focus = next;
                                dirty = true;
                            }
                            break :tab;
                        }
                    }
                }
                // Paste. A Ctrl chord produces no text event on any platform,
                // so the clipboard has to be read here -- at the one point a
                // key is seen before the app. The bytes are borrowed for the
                // dispatch only; a hook that keeps them must copy them.
                if (!k.repeat and k.mods.ctrl and !k.mods.alt and
                    (k.code == 'v' or k.code == 'V'))
                {
                    if (window.clipboardText()) |clip| {
                        if (rt.on_text) |hook| {
                            if (hook(&rt.state, clip)) |msg| {
                                const action = rt.dispatch(msg);
                                stats.messages += 1;
                                if (action.quit) running = false;
                                dirty = dirty or action.repaint;
                            }
                            break :tab;
                        }
                    }
                }
                // A popup owns the keyboard while it is open. This has to run
                // BEFORE activation: the field under an open list carries the
                // toggle, so Enter would otherwise shut the list instead of
                // choosing from it, and the arrows would fall through to the
                // app while a menu was sitting on screen.
                //
                // Escape is deliberately NOT handled here. Closing without
                // committing is the app's decision -- it owns `open` -- so that
                // key falls through to `on_key` like any other.
                if (frame) |*f| {
                    if (f.openPopup(rt.focus)) |popup| {
                        if (elmz.Frame(M).popupRows(popup)) |rows| {
                            if (rows.items.len > 0) {
                                const named = k.named orelse break :tab;
                                const down = switch (named) {
                                    .up, .left => @as(i32, -1),
                                    .down, .right => @as(i32, 1),
                                    else => @as(i32, 0),
                                };
                                if (down != 0) {
                                    if (!k.repeat) {
                                        // No wrap: the ends of a list are
                                        // usually off-screen, so wrapping reads
                                        // as a jump to somewhere unrelated.
                                        const last: i32 = @intCast(rows.items.len - 1);
                                        const cur: i32 = if (rows.active.*) |a| @as(i32, @intCast(a)) else if (down > 0) -1 else last + 1;
                                        const next: u16 = @intCast(std.math.clamp(cur + down, 0, last));
                                        if (rows.active.* == null or rows.active.*.? != next) {
                                            rows.active.* = next;
                                            dirty = true;
                                        }
                                    }
                                    break :tab;
                                }
                                if (!k.repeat and k.named == .enter) {
                                    if (rows.active.*) |a| {
                                        if (a < rows.items.len) {
                                            const item = rows.items[a];
                                            if (!item.disabled) if (item.msg) |msg| {
                                                const action = rt.dispatch(msg);
                                                stats.messages += 1;
                                                if (action.quit) running = false;
                                                dirty = dirty or action.repaint;
                                            };
                                        }
                                    }
                                    break :tab;
                                }
                            }
                        }
                    }
                }
                // Roving: arrows move the cursor inside one tab stop, so a list
                // is navigable without every row being a stop of its own. Only
                // when the focused element is actually a row -- otherwise the
                // key is the app's.
                if (frame) |*f| {
                    const delta: i32 = if (k.named) |n| switch (n) {
                        .up, .left => @as(i32, -1),
                        .down, .right => @as(i32, 1),
                        else => @as(i32, 0),
                    } else 0;
                    if (delta != 0 and !k.repeat) {
                        if (f.rovingMove(rt.focus, delta)) |r| {
                            if (r.key != rt.focus) {
                                rt.focus = r.key;
                                dirty = true;
                            }
                            break :tab;
                        }
                    }
                }
                // Activation, before the app's hook: Enter, or Space, on a
                // focused control that carries a message. Which controls those
                // are is derived, not declared -- see `Frame.activate`. The
                // consequence worth knowing is that a text field carries no
                // message, so it never activates and Enter falls through to
                // `on_key`, which is the only code that knows what Enter means
                // inside a text value.
                //
                // Repeats are ignored: a held Enter must not fire the focused
                // button once per tick.
                if (!k.repeat and (k.named == .enter or k.code == ' ')) {
                    if (frame) |*f| {
                        if (f.activate(rt.focus)) |msg| {
                            const action = rt.dispatch(msg);
                            stats.messages += 1;
                            if (action.quit) running = false;
                            dirty = dirty or action.repaint;
                            break :tab;
                        }
                    }
                }
                // Shortcuts, ahead of the app's hook. The runtime is the only
                // thing that sees a key before the app, and a menu item that
                // stored "Ctrl+S" as text would drift from the binding the
                // moment either changed -- so the chord lives here and the
                // label is derived from it. Only the DOWN fires: a release
                // running a command again is how one press saves twice.
                if (!k.repeat and @hasField(App, "shortcuts") and App.shortcuts.len > 0) {
                    if (elmz.shortcutFor(M, App.shortcuts, k, rt.text_editing)) |msg| {
                        const action = rt.dispatch(msg);
                        stats.messages += 1;
                        if (action.quit) running = false;
                        dirty = dirty or action.repaint;
                        break :tab;
                    }
                }
                const hook = rt.on_key orelse break :tab;
                if (hook(&rt.state, k, .down)) |msg| {
                    const action = rt.dispatch(msg);
                    stats.messages += 1;
                    if (action.quit) running = false;
                    dirty = dirty or action.repaint;
                }
            },
            // Releases share the hook rather than getting a second one: an app
            // that needs press/release asymmetry reads `phase`, and one that
            // does not stays a single switch arm.
            .key_up => |k| if (rt.on_key) |hook| {
                if (hook(&rt.state, k, .up)) |msg| {
                    const action = rt.dispatch(msg);
                    stats.messages += 1;
                    if (action.quit) running = false;
                    dirty = dirty or action.repaint;
                }
            },

            // A scroll viewport under the pointer consumes the tick first. Its
            // offset is runtime state, so there is no message to carry a
            // continuous value and nothing for an app to route. A tick the
            // runtime cannot scroll falls through to `on_wheel`, which is what
            // keeps an app's own wheel handling working.
            //
            // Topmost-first over the hit list, same order `hit()` uses, so a
            // viewport nested in another viewport takes the tick.
            .wheel => |w| blk: {
                if (frame) |*f| {
                    const p = [2]f32{ w.x, w.y };
                    var i = f.hits.len;
                    while (i > 0) {
                        i -= 1;
                        const h = f.hits[i];
                        const sv = h.scroll orelse continue;
                        const key = h.key orelse continue;
                        if (!h.rect.containsRounded(h.radius, p) or !h.clip.contains(p)) continue;
                        const max_off = @max(0, sv.content_h - sv.view_h);
                        if (max_off <= 0) continue;
                        const before = rt.scrollOffset(key);
                        const next = std.math.clamp(before + w.dy * scroll_step, 0, max_off);
                        // A tick against the end of the content changed
                        // nothing, so it must not bill a repaint.
                        if (next == before) break :blk;
                        rt.scrollTo(key, next);
                        dirty = true;
                        break :blk;
                    }
                }
                if (rt.on_wheel) |hook| {
                    if (hook(&rt.state, w)) |msg| {
                        const action = rt.dispatch(msg);
                        stats.messages += 1;
                        if (action.quit) running = false;
                        dirty = dirty or action.repaint;
                    }
                }
            },
            .text => |bytes| if (rt.on_text) |hook| {
                if (hook(&rt.state, bytes)) |msg| {
                    const action = rt.dispatch(msg);
                    stats.messages += 1;
                    if (action.quit) running = false;
                    dirty = dirty or action.repaint;
                }
            },
        }

        if (opts.max_events) |max| {
            if (stats.events >= max) running = false;
        }
    }

    if (frame) |*f| f.deinit();
    return stats;
}

/// One wheel notch, in logical units. SDL reports whole clicks, and a notch
/// that moves less than a line reads as a trackpad that is broken.
const scroll_step: f32 = 48;

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
    /// The size the next `.resize` event adopts. A real backend has already
    /// resized by the time it reports the event -- that is what makes the event
    /// payload-free -- so the fake has to adopt it on the way out too, or it
    /// would report a resize and keep answering the old size.
    pending: elmz.Size = .{ .w = 200, .h = 120 },
    /// What the last present actually handed over. The bug this guards is a
    /// size mismatch between the canvas and the window, which nothing else in
    /// the harness can see: a hash of the pixels says the frame was painted,
    /// not that it was the right SIZE.
    presented_len: usize = 0,
    presented_size: elmz.Size = .{ .w = 0, .h = 0 },
    /// Device pixels per logical unit, as the platform would report it. Default
    /// 1x: a test that says nothing about density is testing the unscaled path.
    density: f32 = 1.0,
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
        .density = getDensity,
        .deinit = noop,
    };

    fn poll(ptr: *anyopaque, _: i32) ?elmz.Event {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.i < self.events.len) {
            defer self.i += 1;
            const ev = self.events[self.i];
            switch (ev) {
                .resize => {
                    self.w = self.pending.w;
                    self.h = self.pending.h;
                },
                else => {},
            }
            return ev;
        }
        // A timeout (null) keeps the loop going, which is exactly how a
        // worker's result gets drained. Then quit, so tests terminate.
        if (self.spun < self.idle) {
            self.spun += 1;
            // Yield, or this test measures the machine instead of the code. The
            // loop has to still be polling when the job thread posts its result,
            // and 20k tight iterations finish in well under a millisecond -- so
            // under load the spin can run out first. That is exactly how it
            // failed once, while a build was saturating the CPU. A yield per
            // idle poll gives the scheduler the turn the tight loop never gave
            // it, at no cost to what the test asserts.
            std.Thread.yield() catch {};
            return null;
        }
        return .quit;
    }

    fn present(ptr: *anyopaque, px: []const u8, s: elmz.Size) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.frames += 1;
        self.presented_len = px.len;
        self.presented_size = s;
        self.last_hash = std.hash.Wyhash.hash(0, px);
    }

    fn size(ptr: *anyopaque) elmz.Size {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return .{ .w = self.w, .h = self.h };
    }

    fn getDensity(ptr: *anyopaque) f32 {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return self.density;
    }

    fn noop(_: *anyopaque) void {}
};

fn testCanvas(gpa: std.mem.Allocator, w: u32, h: u32) !software.Canvas {
    var cv = try software.Canvas.init(gpa, w, h);
    cv.setFont(@embedFile("../src/font.ttf"));
    return cv;
}

test "runner paints once, then stops when the window says quit" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
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

// The canvas was allocated once, outside the loop, while the frame was built
// from `window.size()` read live. After a resize the tree laid out for the NEW
// box painted into the OLD buffer: the pixels were a cropped corner of the
// layout, and the hit rects -- built at the new size -- pointed at places the
// picture did not show. That is why this asserts the presented SLICE LENGTH and
// not just that a frame happened.
test "a resize rebuilds the canvas at the size the window reports" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    const events = [_]elmz.Event{ .resize, .quit };
    var fake: Fake = .{ .events = &events, .pending = .{ .w = 400, .h = 300 } };

    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 400), canvas.w);
    try std.testing.expectEqual(@as(u32, 300), canvas.h);
    // The whole point: what reached the backend is a buffer of the new size.
    try std.testing.expectEqual(@as(usize, 400 * 300 * 4), fake.presented_len);
    try std.testing.expectEqual(@as(f32, 400), fake.presented_size.w);
    try std.testing.expectEqual(@as(f32, 300), fake.presented_size.h);
}

// Density is the one number above the renderer that is not logical. It is worth
// pinning down in both directions: the canvas must be allocated in DEVICE pixels
// (or a 2x display shows a quarter of the screen), and layout must stay in
// LOGICAL units (or every rect in an app is written twice).
test "density sizes the canvas in device pixels while layout stays logical" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    // What the same text measures at 1x, through the same entry point.
    const at_1x = canvas.renderer().measureText("inc", 16).width;

    const events = [_]elmz.Event{.quit};
    var fake: Fake = .{ .events = &events, .density = 2.0 };

    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    // Device pixels: a 200x120 logical window on a 2x display owns 400x240.
    try std.testing.expectEqual(@as(f32, 2), canvas.scale);
    try std.testing.expectEqual(@as(u32, 400), canvas.w);
    try std.testing.expectEqual(@as(u32, 240), canvas.h);
    try std.testing.expectEqual(@as(usize, 400 * 240 * 4), fake.presented_len);

    // ...and the measurement is divided back, so a logical layout is unmoved by
    // the density it was measured at. Measured at 2x, NOT scaled from 1x: the
    // glyphs are grid-fitted at the size they will actually be rasterised at,
    // so the two agree to within a pixel rather than exactly.
    const at_2x = canvas.renderer().measureText("inc", 16).width;
    try std.testing.expectApproxEqAbs(at_1x, at_2x, 1.0);

    // A layout built at 2x still measures a button as label + 24, in logical
    // units -- the 48 would be device pixels leaking upward.
    var f = try rt.frame(.{ .w = 200, .h = 120 }, canvas.renderer());
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.hits.len);
    const rect = f.hits[0].rect;
    try std.testing.expectApproxEqAbs(at_2x + 24, rect.w, 0.01);
}

// A minimised window reports 0x0. Honouring that would free the pixel buffer
// and hand the backend an empty slice the moment the compositor asks for a
// frame, so the last one is kept instead.
test "a minimised window keeps the frame it already had" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    const events = [_]elmz.Event{ .resize, .quit };
    var fake: Fake = .{ .events = &events, .pending = .{ .w = 0, .h = 0 } };

    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 200), canvas.w);
    try std.testing.expectEqual(@as(u32, 120), canvas.h);
    try std.testing.expectEqual(@as(usize, 200 * 120 * 4), fake.presented_len);

    // Density must not resurrect the zero: 0 * anything is still no canvas.
    try std.testing.expectEqual(@as(f32, 1), canvas.scale);
}

test "layout measures with the glyph metrics of the drawing backend" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
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
    const label = software.testing_font.get().measure("inc", 16);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
        .frost => |f2| try std.testing.expect(std.math.isFinite(f2.blur)),
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
    var canvas = try testCanvas(gpa, 240, 200);
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
    var small = try testCanvas(gpa, 90, 70);
    defer small.deinit();
    var g = try rt.frame(.{ .w = 90, .h = 70 }, small.renderer());
    defer g.deinit();
    for (g.prims) |p| switch (p) {
        .quad => |q| try std.testing.expect(std.math.isFinite(q.rect.x + q.rect.y + q.rect.w + q.rect.h)),
        .rrect => |q| try std.testing.expect(std.math.isFinite(q.rect.x + q.rect.w + q.radius)),
        .text => |t| try std.testing.expect(std.math.isFinite(t.x + t.y)),
        .halo => |h| try std.testing.expect(std.math.isFinite(h.rect.x + h.halo.blur)),
        .frost => |f3| try std.testing.expect(std.math.isFinite(f3.blur)),
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
    var canvas = try testCanvas(gpa, 300, 300);
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
    const m = software.testing_font.get().measure(
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
    var canvas = try testCanvas(gpa, 200, 120);
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
            // A frost rewrites pixels inside its rect; it adds no ink.
            .frost => {},
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
    var canvas = try testCanvas(gpa, 200, 120);
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
        var canvas = try testCanvas(gpa, 200, 120);
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
        var canvas = try testCanvas(gpa, 500, 300);
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
                const m = software.testing_font.get().measure(t.bytes, t.size);
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
    var canvas = try testCanvas(gpa, 200, 120);
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
        .frost => {},
    };
    // One fill, one label. Two quads means something upstream is drawing the
    // same rect twice, which is invisible on screen and wrong everywhere else.
    try std.testing.expectEqual(@as(usize, 1), quads);
    try std.testing.expectEqual(@as(usize, 1), texts);
    try std.testing.expectEqual(@as(usize, 2), f.prims.len);
}

test "a bar paints a track and a value fill, and nothing twice" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
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
        .frost => {},
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
    var canvas = try testCanvas(gpa, 120, 80);
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
    try std.testing.expectEqual(@as(i32, -1), effectiveTimeout(.{}, false, false, false, false));
    // Watched: bounded, or an edit waits for the pointer to enter the window.
    try std.testing.expectEqual(@as(i32, 250), effectiveTimeout(.{ .theme_path = "theme.zon" }, false, true, false, false));
    // A command in flight keeps its own tighter budget.
    try std.testing.expectEqual(@as(i32, 5), effectiveTimeout(.{ .theme_path = "theme.zon" }, true, true, false, false));
    // An app that already asked for less does not get slowed down.
    try std.testing.expectEqual(@as(i32, 30), effectiveTimeout(.{ .poll_timeout_ms = 30 }, false, true, false, false));
    // Animating outranks an idle block: a frame clock that waits for input is
    // not a clock. Busy still wins, because a command result is due sooner.
    try std.testing.expectEqual(@as(i32, 8), effectiveTimeout(.{}, false, false, true, false));
    try std.testing.expectEqual(@as(i32, 8), effectiveTimeout(.{ .poll_timeout_ms = 30 }, false, false, true, false));
    try std.testing.expectEqual(@as(i32, 5), effectiveTimeout(.{}, true, false, true, false));
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

test "the font name rides the chain: user wins, an omitting override inherits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [64]u8 = undefined;
    var ub: [64]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "theme.defaults.zon", .data = ".{ .version = 2, .theme = .{ .font = \"Base Face\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{ .version = 2, .theme = .{ .colors = .{ .accent = 0x89b4fa } } }" });

    // An override that omits `.font` inherits the developer's, the same rule the
    // colours follow -- otherwise one file would mean two things.
    {
        const chain = resolveChain(struct {}, gpa, io, .{}, tmpPath(&bb, tmp, "theme.defaults.zon") catch unreachable, tmpPath(&ub, tmp, "theme.zon") catch unreachable);
        try std.testing.expectEqualStrings("Base Face", chain.fontName().?);
    }

    // And the end user naming one wins outright.
    try tmp.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{ .version = 2, .theme = .{ .font = \"User Face\" } }" });
    {
        const chain = resolveChain(struct {}, gpa, io, .{}, tmpPath(&bb, tmp, "theme.defaults.zon") catch unreachable, tmpPath(&ub, tmp, "theme.zon") catch unreachable);
        try std.testing.expectEqualStrings("User Face", chain.fontName().?);
    }
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
    var c = try testCanvas(std.testing.allocator, 260, 120);
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

test "keystrokes and typed text reach the app's hooks, and null does not repaint" {
    const gpa = std.testing.allocator;
    const KMsg = enum { keyed, typed };
    const KState = struct { downs: i32 = 0, ups: i32 = 0, typed_len: usize = 0, first: u8 = 0 };

    const Hooks = struct {
        fn update(s: *KState, m: KMsg) elmz.Action(KMsg) {
            switch (m) {
                .keyed => s.downs += 1,
                .typed => {},
            }
            return .{};
        }
        fn view(s: *KState, ui: *elmz.Ui(KMsg)) *elmz.Element(KMsg) {
            return ui.textFmt("{d}", .{s.downs}, 20);
        }
        // 'a' is ours, everything else is not. The null path is half the
        // contract, so the test proves that half too.
        fn onKey(s: *KState, k: elmz.Key, p: elmz.Phase) ?KMsg {
            if (p == .up) {
                s.ups += 1;
                return null;
            }
            if (k.code != 'a') return null;
            return .keyed;
        }
        fn onText(s: *KState, bytes: []const u8) ?KMsg {
            if (bytes.len == 0) return null;
            s.typed_len += bytes.len;
            s.first = bytes[0];
            return .typed;
        }
    };

    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();
    var rt = elmz.Runtime(KState, KMsg).init(gpa, .{}, Hooks.update, Hooks.view);
    defer rt.deinit();
    rt.on_key = Hooks.onKey;
    rt.on_text = Hooks.onText;

    var fake = Fake{
        .events = &.{
            .{ .key = .{ .code = 'a' } },
            .{ .key = .{ .code = 'q' } }, // unhandled: no message, no repaint
            .{ .key_up = .{ .code = 'a' } },
            .{ .text = "he" },
            .quit,
        },
        .idle = 2,
    };
    const stats = try run(struct {}, KState, KMsg, &rt, &canvas, fake.window(), .{});

    try std.testing.expectEqual(@as(i32, 1), rt.state.downs); // 'a' only, not 'q'
    try std.testing.expectEqual(@as(i32, 1), rt.state.ups); // release was seen
    try std.testing.expectEqual(@as(usize, 2), rt.state.typed_len); // borrowed slice read in time
    try std.testing.expectEqual(@as(u8, 'h'), rt.state.first);
    // Two messages, not four: the unhandled key and the release returned null.
    try std.testing.expectEqual(@as(u32, 2), stats.messages);
}

test "a declared font path that cannot be read raises the band" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const bytes = attachFont(&rt.ui, &canvas, gpa, threaded.io(), "no-such-font.ttf");
    try std.testing.expect(bytes == null);

    // The band is painted from per-frame state, so the failure only becomes
    // visible once a frame runs -- asserting earlier would test the staging
    // area instead of what the user sees.
    var frame = try paintInto(TState, TMsg, &rt, &canvas);
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rt.ui.failMessage(), "cannot read font: no-such-font.ttf") != null);
}

test "an app that declares no font path stays silent" {
    const gpa = std.testing.allocator;
    var canvas = try software.Canvas.init(gpa, 200, 120);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, tView);
    defer rt.deinit();

    var frame = try paintInto(TState, TMsg, &rt, &canvas);
    defer frame.deinit();
    try std.testing.expect(rt.ui.failed == false);
}

test "tab moves focus in document order and never reaches the app hook" {
    const gpa = std.testing.allocator;
    const TabM = enum { a, b };
    const TabS = struct { hook_calls: u32 = 0 };

    const Hooks = struct {
        fn update(s: *TabS, m: TabM) elmz.Action(TabM) {
            _ = m;
            s.hook_calls += 100;
            return .{};
        }
        fn view(s: *TabS, ui: *elmz.Ui(TabM)) *elmz.Element(TabM) {
            _ = s;
            const a = ui.button(.{ .label = "a", .msg = .a, .key = 1 });
            const b = ui.button(.{ .label = "b", .msg = .b, .key = 2 });
            a.focusable = true;
            b.focusable = true;
            return ui.column(.{ .children = &.{ a, b } });
        }
        /// Claims nothing, but counts: if Tab reached here the count would move,
        /// so the count is the proof the runtime swallowed the key instead.
        fn onKey(s: *TabS, k: elmz.Key, p: elmz.Phase) ?TabM {
            _ = k;
            _ = p;
            s.hook_calls += 1;
            return null;
        }
    };

    var canvas = try testCanvas(gpa, 200, 160);
    defer canvas.deinit();
    var rt = elmz.Runtime(TabS, TabM).init(gpa, .{}, Hooks.update, Hooks.view);
    defer rt.deinit();
    rt.on_key = Hooks.onKey;

    var fake = Fake{
        .events = &.{
            .{ .key = .{ .named = .tab } }, // nothing focused -> first
            .{ .key = .{ .named = .tab } }, // -> second
            .{ .key = .{ .named = .tab, .mods = .{ .shift = true } } }, // back to first
            .quit,
        },
        .idle = 2,
    };
    const stats = try run(struct {}, TabS, TabM, &rt, &canvas, fake.window(), .{});

    try std.testing.expectEqual(@as(?u64, 1), rt.focus);
    try std.testing.expectEqual(@as(u32, 0), stats.messages); // traversal is not a message
    try std.testing.expectEqual(@as(u32, 0), rt.state.hook_calls); // and not the app's key
}

test "tab falls through to the app when nothing can take focus" {
    const gpa = std.testing.allocator;
    const PlainM = enum { typed_tab };
    const PlainS = struct { claimed: u32 = 0 };

    const Hooks = struct {
        fn update(s: *PlainS, m: PlainM) elmz.Action(PlainM) {
            _ = m;
            s.claimed += 1;
            return .{};
        }
        fn view(s: *PlainS, ui: *elmz.Ui(PlainM)) *elmz.Element(PlainM) {
            _ = s;
            return ui.text(.{ .label = "no controls here", .size = 14 });
        }
        fn onKey(s: *PlainS, k: elmz.Key, p: elmz.Phase) ?PlainM {
            _ = s;
            if (p == .up or k.named != .tab) return null;
            return .typed_tab;
        }
    };

    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();
    var rt = elmz.Runtime(PlainS, PlainM).init(gpa, .{}, Hooks.update, Hooks.view);
    defer rt.deinit();
    rt.on_key = Hooks.onKey;

    var fake = Fake{
        .events = &.{
            .{ .key = .{ .named = .tab } },
            .{ .key_up = .{ .named = .tab } },
            .quit,
        },
        .idle = 2,
    };
    const stats = try run(struct {}, PlainS, PlainM, &rt, &canvas, fake.window(), .{});

    // With no focusable candidate, Tab is genuinely not the runtime's: it
    // reaches the hook and the message counts exactly once.
    try std.testing.expectEqual(@as(?u64, null), rt.focus);
    try std.testing.expectEqual(@as(u32, 1), rt.state.claimed);
    try std.testing.expectEqual(@as(u32, 1), stats.messages);
}

test "a release that claimed nothing does not repaint" {
    const gpa = std.testing.allocator;
    const RMsg = enum { hit };

    const Hooks = struct {
        fn update(s: *u8, m: RMsg) elmz.Action(RMsg) {
            _ = s;
            _ = m;
            return .{};
        }
        fn view(s: *u8, ui: *elmz.Ui(RMsg)) *elmz.Element(RMsg) {
            _ = s;
            return ui.button(.{ .label = "go", .msg = .hit, .key = 1, .width = 60, .height = 24 });
        }
    };

    var canvas = try testCanvas(gpa, 120, 80);
    defer canvas.deinit();
    var rt = elmz.Runtime(u8, RMsg).init(gpa, 0, Hooks.update, Hooks.view);
    defer rt.deinit();

    // A release with no press before it, over empty space: nothing is claimed,
    // so nothing can look different and there is nothing to paint.
    var fake = Fake{
        .events = &.{
            .{ .pointer_up = .{ 110, 70 } },
            .quit,
        },
        .idle = 2,
    };
    const stats = try run(struct {}, u8, RMsg, &rt, &canvas, fake.window(), .{});

    try std.testing.expectEqual(@as(u32, 1), stats.frames); // the first paint only
}

test "a press and release on a control still repaints twice" {
    const gpa = std.testing.allocator;
    const RepaintMsg = enum { hit };

    const Hooks = struct {
        fn update(s: *u8, m: RepaintMsg) elmz.Action(RepaintMsg) {
            _ = s;
            _ = m;
            return .{};
        }
        fn view(s: *u8, ui: *elmz.Ui(RepaintMsg)) *elmz.Element(RepaintMsg) {
            _ = s;
            return ui.button(.{ .label = "go", .msg = .hit, .key = 1, .width = 60, .height = 24 });
        }
    };

    var canvas = try testCanvas(gpa, 120, 80);
    defer canvas.deinit();
    var rt = elmz.Runtime(u8, RepaintMsg).init(gpa, 0, Hooks.update, Hooks.view);
    defer rt.deinit();

    var fake = Fake{
        .events = &.{
            .{ .pointer_down = .{ 10, 10 } }, // claims the button: pressed look
            .{ .pointer_up = .{ 11, 11 } }, // releases it: look comes off
            .quit,
        },
        .idle = 2,
    };
    const stats = try run(struct {}, u8, RepaintMsg, &rt, &canvas, fake.window(), .{});

    try std.testing.expectEqual(@as(u32, 3), stats.frames); // initial, press, release
}

test "a viewport under the pointer takes the wheel before the app sees it" {
    const gpa = std.testing.allocator;
    const VWMsg = enum { nop };
    const VWState = struct { hook_calls: u32 = 0 };

    const Hooks = struct {
        fn update(s: *VWState, m: VWMsg) elmz.Action(VWMsg) {
            _ = s;
            _ = m;
            return .{};
        }
        /// Ten 20px rows behind a 60px viewport: 200 of content, 140 of travel.
        fn view(_: *VWState, ui: *elmz.Ui(VWMsg)) *elmz.Element(VWMsg) {
            var kids: [10]*elmz.Element(VWMsg) = undefined;
            for (&kids) |*k| k.* = ui.rect(.{ .width = 50, .height = 20 });
            const vp = ui.scroll(.{ .key = 9, .height = 60, .child = ui.column(.{ .children = &kids }) });
            return ui.column(.{ .children = &.{vp} });
        }
        fn onWheel(s: *VWState, w: elmz.Wheel) ?VWMsg {
            _ = w;
            s.hook_calls += 1;
            return null;
        }
    };

    var canvas = try testCanvas(gpa, 120, 80);
    defer canvas.deinit();
    var rt = elmz.Runtime(VWState, VWMsg).init(gpa, .{}, Hooks.update, Hooks.view);
    defer rt.deinit();
    rt.on_wheel = Hooks.onWheel;

    var fake = Fake{
        .events = &.{
            .{ .wheel = .{ .dy = 2, .x = 10, .y = 10 } },
            .quit,
        },
        .idle = 2,
    };
    _ = try run(struct {}, VWState, VWMsg, &rt, &canvas, fake.window(), .{});

    // Two notches at 48 units each, and the app's hook never ran: the offset is
    // runtime state, so there is nothing for the app to route.
    try std.testing.expectEqual(@as(f32, 96), rt.scrollOffset(9));
    try std.testing.expectEqual(@as(u32, 0), rt.state.hook_calls);
}

test "a wheel event reaches the app's hook and an unclaimed one repaints nothing" {
    const gpa = std.testing.allocator;
    const WMsg = enum { scrolled };
    const WState = struct { dy: f32 = 0, dx: f32 = 0, at_x: f32 = 0, calls: u32 = 0, claim: bool = true };

    const Hooks = struct {
        fn update(s: *WState, m: WMsg) elmz.Action(WMsg) {
            _ = m;
            s.calls += 1;
            return .{};
        }
        fn view(s: *WState, ui: *elmz.Ui(WMsg)) *elmz.Element(WMsg) {
            _ = s;
            return ui.text(.{ .label = "scrollable", .size = 14 });
        }
        fn onWheel(s: *WState, w: elmz.Wheel) ?WMsg {
            s.dy = w.dy;
            s.dx = w.dx;
            s.at_x = w.x;
            s.calls += 100; // reached at all
            if (!s.claim) return null;
            return .scrolled;
        }
    };

    // Claimed: the app gets the deltas AND its message, exactly once.
    {
        var canvas = try testCanvas(gpa, 120, 80);
        defer canvas.deinit();
        var rt = elmz.Runtime(WState, WMsg).init(gpa, .{ .claim = true }, Hooks.update, Hooks.view);
        defer rt.deinit();
        rt.on_wheel = Hooks.onWheel;

        var fake = Fake{
            .events = &.{
                .{ .wheel = .{ .dx = -1, .dy = 2.5, .x = 40, .y = 30 } },
                .quit,
            },
            .idle = 2,
        };
        const stats = try run(struct {}, WState, WMsg, &rt, &canvas, fake.window(), .{});

        try std.testing.expectEqual(@as(f32, 2.5), rt.state.dy); // deltas arrive unnormalised
        try std.testing.expectEqual(@as(f32, -1), rt.state.dx);
        try std.testing.expectEqual(@as(f32, 40), rt.state.at_x); // and with their target
        try std.testing.expectEqual(@as(u32, 1), stats.messages);
    }

    // Unclaimed: the hook still sees it, and costs no frame. Scrolling over a
    // widget that does not scroll must not repaint at scroll-event rate.
    {
        var canvas = try testCanvas(gpa, 120, 80);
        defer canvas.deinit();
        var rt = elmz.Runtime(WState, WMsg).init(gpa, .{ .claim = false }, Hooks.update, Hooks.view);
        defer rt.deinit();
        rt.on_wheel = Hooks.onWheel;

        var fake = Fake{
            .events = &.{
                .{ .wheel = .{ .dy = 1 } },
                .{ .wheel = .{ .dy = 1 } },
                .{ .wheel = .{ .dy = 1 } },
                .quit,
            },
            .idle = 2,
        };
        const stats = try run(struct {}, WState, WMsg, &rt, &canvas, fake.window(), .{});

        try std.testing.expectEqual(@as(u32, 300), rt.state.calls); // three wheel events, no messages
        try std.testing.expectEqual(@as(u32, 0), stats.messages);
        try std.testing.expectEqual(@as(u32, 1), stats.frames); // the first paint only
    }
}

var clock_now: u64 = 0;
fn stepNow() u64 {
    clock_now += 5 * std.time.ns_per_ms;
    return clock_now;
}

test "the frame clock delivers dt while the app animates, and stops when told" {
    const gpa = std.testing.allocator;
    const ClockMsg = enum { ticked };
    const ClockState = struct { ticks: u32 = 0, sum: f32 = 0, seen: u32 = 0 };

    const Hooks = struct {
        fn update(s: *ClockState, m: ClockMsg) elmz.Action(ClockMsg) {
            _ = m;
            s.seen += 1;
            // Three ticks and it settles: the app, not the runtime, decides.
            return .{ .animate = s.seen < 3 };
        }
        fn view(s: *ClockState, ui: *elmz.Ui(ClockMsg)) *elmz.Element(ClockMsg) {
            _ = s;
            return ui.text(.{ .label = "animating", .size = 14 });
        }
        fn onTick(s: *ClockState, dt: f32) ?ClockMsg {
            s.ticks += 1;
            s.sum += dt;
            return .ticked;
        }
    };

    var canvas = try testCanvas(gpa, 120, 80);
    defer canvas.deinit();
    var rt = elmz.Runtime(ClockState, ClockMsg).init(gpa, .{}, Hooks.update, Hooks.view);
    defer rt.deinit();
    rt.on_tick = Hooks.onTick;
    rt.animate = true;

    clock_now = 0;
    var fake = Fake{ .events = &.{}, .idle = 3 };
    const stats = try run(struct {}, ClockState, ClockMsg, &rt, &canvas, fake.window(), .{ .now_ns = stepNow });

    try std.testing.expectEqual(@as(u32, 3), rt.state.ticks); // each tick asked for one more
    try std.testing.expectApproxEqAbs(@as(f32, 0.015), rt.state.sum, 1e-5); // 3 x 5ms of real dt
    try std.testing.expectEqual(@as(u32, 3), stats.messages);
    try std.testing.expect(!rt.animate); // the runtime honoured animate = false
}

test "a clock that nobody listens to is not a clock: no on_tick, no ticks" {
    const gpa = std.testing.allocator;
    const QuietMsg = enum { none };
    const QuietState = struct { seen: u32 = 0 };

    const Hooks = struct {
        fn update(s: *QuietState, m: QuietMsg) elmz.Action(QuietMsg) {
            _ = m;
            s.seen += 1;
            return .{};
        }
        fn view(s: *QuietState, ui: *elmz.Ui(QuietMsg)) *elmz.Element(QuietMsg) {
            _ = s;
            return ui.text(.{ .label = "still", .size = 14 });
        }
    };

    var canvas = try testCanvas(gpa, 120, 80);
    defer canvas.deinit();
    var rt = elmz.Runtime(QuietState, QuietMsg).init(gpa, .{}, Hooks.update, Hooks.view);
    defer rt.deinit();
    rt.animate = true; // wants frames, but declares no hook to receive them

    clock_now = 0;
    var fake = Fake{ .events = &.{}, .idle = 3 };
    const stats = try run(struct {}, QuietState, QuietMsg, &rt, &canvas, fake.window(), .{ .now_ns = stepNow });

    try std.testing.expectEqual(@as(u32, 0), rt.state.seen);
    try std.testing.expectEqual(@as(u32, 1), stats.frames); // no message, no repaint
}

// ---------------------------------------------------------------------------
// thumb drag
// ---------------------------------------------------------------------------
// One viewport, ten 20px rows, a 100px view: 200 of content, so the offset
// maxes at exactly 100 and one unit of thumb travel is worth two of content.
// The thumb is therefore 50 tall at the top, and its grab strip is the right
// `scrollbar_grab` px of the viewport -- x 186..200 when the view is 200 wide.
const DragMsg = enum { tap };
const DragState = struct {};

fn dragUpdate(s: *DragState, m: DragMsg) elmz.Action(DragMsg) {
    _ = s;
    _ = m;
    return .{};
}

fn dragView(_: *DragState, ui: *elmz.Ui(DragMsg)) *elmz.Element(DragMsg) {
    var kids: [10]*elmz.Element(DragMsg) = undefined;
    for (&kids, 0..) |*k, i| {
        k.* = ui.rect(.{ .width = 80, .height = 20, .on_press = .tap, .key = 100 + i });
    }
    const col = ui.column(.{ .children = &kids });
    const vp = ui.scroll(.{ .key = 7, .height = 100, .child = col });
    return ui.column(.{ .children = &.{vp} });
}

test "dragging the thumb moves the content by the viewport's ratio, and letting go stops it" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();
    var rt = elmz.Runtime(DragState, DragMsg).init(gpa, .{}, dragUpdate, dragView);
    defer rt.deinit();

    var fake = Fake{
        .events = &.{
            .{ .pointer_down = .{ 195, 5 } }, // on the thumb
            .{ .pointer_move = .{ 195, 15 } }, // 10 down
            .{ .pointer_up = .{ 195, 15 } },
            .{ .pointer_move = .{ 195, 45 } }, // still moving, drag is over
            .quit,
        },
        .idle = 1,
    };
    _ = try run(struct {}, DragState, DragMsg, &rt, &canvas, fake.window(), .{});

    // 10 of pointer travel x (200 content / 100 view) = 20 of content. The
    // direction matters more than the magnitude: dy grows downward, and
    // dragging the thumb DOWN has to move the content UP, i.e. increase the
    // offset. An inverted sign still scrolls, just backwards, which is why
    // this asserts a positive number.
    try std.testing.expectEqual(@as(f32, 20), rt.scrollOffset(7));
}

test "a cancelled drag stops moving the content" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();
    var rt = elmz.Runtime(DragState, DragMsg).init(gpa, .{}, dragUpdate, dragView);
    defer rt.deinit();

    // The release does not always arrive -- focus can go, or the pointer can
    // leave the window. Everything the claim touches has to be dropped with
    // it, or the content keeps following a pointer that is no longer dragging.
    var fake = Fake{
        .events = &.{
            .{ .pointer_down = .{ 195, 5 } },
            .{ .pointer_move = .{ 195, 15 } },
            .pointer_cancel,
            .{ .pointer_move = .{ 195, 45 } },
            .quit,
        },
        .idle = 1,
    };
    _ = try run(struct {}, DragState, DragMsg, &rt, &canvas, fake.window(), .{});

    try std.testing.expectEqual(@as(f32, 20), rt.scrollOffset(7));
}

test "a press on the content is not a scroll drag" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 120);
    defer canvas.deinit();
    var rt = elmz.Runtime(DragState, DragMsg).init(gpa, .{}, dragUpdate, dragView);
    defer rt.deinit();

    // Row 0 is 80 wide, so x=40 is over content and nowhere near the strip.
    // Pressing it and moving must scroll nothing: the drag is keyed on the
    // region's `drag` marker, not on the pointer being inside a viewport.
    var fake = Fake{
        .events = &.{
            .{ .pointer_down = .{ 40, 5 } },
            .{ .pointer_move = .{ 40, 45 } },
            .quit,
        },
        .idle = 1,
    };
    _ = try run(struct {}, DragState, DragMsg, &rt, &canvas, fake.window(), .{});

    try std.testing.expectEqual(@as(f32, 0), rt.scrollOffset(7));
}

test "a drag clamps at both ends of the content" {
    const gpa = std.testing.allocator;

    // Far past the bottom: the grab is 10 down and the pointer is 500 down,
    // which is 980 of content in a space that only has 100 to give.
    {
        var canvas = try testCanvas(gpa, 200, 120);
        defer canvas.deinit();
        var rt = elmz.Runtime(DragState, DragMsg).init(gpa, .{}, dragUpdate, dragView);
        defer rt.deinit();
        var fake = Fake{
            .events = &.{
                .{ .pointer_down = .{ 195, 5 } },
                .{ .pointer_move = .{ 195, 500 } },
                .quit,
            },
            .idle = 1,
        };
        _ = try run(struct {}, DragState, DragMsg, &rt, &canvas, fake.window(), .{});
        try std.testing.expectEqual(@as(f32, 100), rt.scrollOffset(7));
    }

    // Far past the top, from a thumb already resting at the bottom: the thumb
    // sits at y 50..100 there, so the grab starts at 60 and ends above zero.
    {
        var canvas = try testCanvas(gpa, 200, 120);
        defer canvas.deinit();
        var rt = elmz.Runtime(DragState, DragMsg).init(gpa, .{}, dragUpdate, dragView);
        defer rt.deinit();
        rt.scrollTo(7, 100);
        var fake = Fake{
            .events = &.{
                .{ .pointer_down = .{ 195, 60 } },
                .{ .pointer_move = .{ 195, 0 } },
                .quit,
            },
            .idle = 1,
        };
        _ = try run(struct {}, DragState, DragMsg, &rt, &canvas, fake.window(), .{});
        try std.testing.expectEqual(@as(f32, 0), rt.scrollOffset(7));
    }
}

const OutState = struct { outside: u32 = 0, clicks: u32 = 0, at: [2]f32 = .{ -1, -1 } };
const OutMsg = enum { clicked, missed };

fn outUpdate(s: *OutState, m: OutMsg) elmz.Action(OutMsg) {
    switch (m) {
        .clicked => s.clicks += 1,
        .missed => s.outside += 1,
    }
    return .{ .repaint = true };
}

fn outView(_: *OutState, ui: *elmz.Ui(OutMsg)) *elmz.Element(OutMsg) {
    const b = ui.button(.{ .label = "go", .msg = .clicked });
    b.key = 1;
    return ui.column(.{ .children = &.{b}, .width = 200, .height = 200 });
}

const OutHooks = struct {
    fn onOutside(s: *OutState, p: [2]f32) ?OutMsg {
        s.at = p;
        return .missed;
    }
};

test "a press that lands on nothing reaches the app, so a popup can dismiss itself" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 200);
    defer canvas.deinit();

    var rt = elmz.Runtime(OutState, OutMsg).init(gpa, .{}, outUpdate, outView);
    defer rt.deinit();
    rt.on_outside = OutHooks.onOutside;

    var probe = try rt.frame(.{ .w = 200, .h = 200 }, canvas.renderer());
    defer probe.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.hits.len);
    const b = probe.hits[0].rect;

    // Bottom-right corner: the column is full-size but claims nothing, so this
    // press lands on empty canvas.
    const empty: [2]f32 = .{ 195, 195 };
    try std.testing.expect(probe.hit(empty) == null);

    const ev = [_]elmz.Event{ .{ .pointer_down = empty }, .{ .pointer_up = empty } };
    var fake: Fake = .{ .events = &ev, .w = 200, .h = 200 };
    _ = try run(struct {}, OutState, OutMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 1), rt.state.outside);
    try std.testing.expectEqual(empty[0], rt.state.at[0]);
    try std.testing.expectEqual(@as(u32, 0), rt.state.clicks);

    // A press that DOES land must not be reported as outside: the hook is for
    // the presses nothing claimed, not for every press.
    const on_btn: [2]f32 = .{ b.x + b.w / 2, b.y + b.h / 2 };
    const ev2 = [_]elmz.Event{ .{ .pointer_down = on_btn }, .{ .pointer_up = on_btn } };
    var fake2: Fake = .{ .events = &ev2, .w = 200, .h = 200 };
    _ = try run(struct {}, OutState, OutMsg, &rt, &canvas, fake2.window(), .{ .poll_timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 1), rt.state.clicks);
    try std.testing.expectEqual(@as(u32, 1), rt.state.outside);
}

fn roveRunnerView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    var kids: [3]*elmz.Element(TMsg) = undefined;
    var i: u16 = 0;
    while (i < 3) : (i += 1) {
        const r = ui.button(.{ .label = "r", .msg = .inc, .key = 40 + i });
        r.focusable = true;
        r.roving = 30;
        r.roving_index = i;
        kids[i] = r;
    }
    return ui.column(.{ .children = &kids });
}

test "an arrow key moves the roving cursor, not just the frame" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 160);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, roveRunnerView);
    defer rt.deinit();
    rt.focus = 40;

    const events = [_]elmz.Event{ .{ .key = .{ .named = .down } }, .quit };
    var fake: Fake = .{ .events = &events };
    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });

    // The frame knew how to move a roving cursor for a while and nothing ever
    // asked it to: `rovingStep` had a test and no caller. This asserts the
    // wiring, which is the half that cannot be seen from a Frame.
    try std.testing.expectEqual(@as(?u64, 41), rt.focus);
}

/// A roving control that actually HAS an owner element (key 30), the way a
/// builder produces one: Tab lands on the owner, never on a row.
fn roveOwnerView(_: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    const owner = ui.button(.{ .label = "list", .msg = .inc, .key = 30 });
    owner.focusable = true;
    var kids: [4]*elmz.Element(TMsg) = undefined;
    kids[0] = owner;
    var i: u16 = 0;
    while (i < 3) : (i += 1) {
        const r = ui.button(.{ .label = "r", .msg = .inc, .key = 40 + i });
        r.focusable = true;
        r.roving = 30;
        r.roving_index = i;
        kids[i + 1] = r;
    }
    return ui.column(.{ .children = &kids });
}

test "an arrow steps into a roving set from the control that owns it" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 200);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, roveOwnerView);
    defer rt.deinit();

    // Where focus ACTUALLY lands: `focusStep` skips every row of a roving
    // control, so Tab stops on the owner. From there an arrow has to be able
    // to step in, or the rows are unreachable by keyboard at all -- the
    // earlier wiring test set focus straight onto a row, a state the runtime
    // never produces on its own.
    rt.focus = 30;

    const down = [_]elmz.Event{ .{ .key = .{ .named = .down } }, .quit };
    var fake: Fake = .{ .events = &down };
    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(@as(?u64, 40), rt.focus);

    // And from inside, the next one moves along the set as before.
    const again = [_]elmz.Event{ .{ .key = .{ .named = .down } }, .quit };
    var fake2: Fake = .{ .events = &again };
    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake2.window(), .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(@as(?u64, 41), rt.focus);

    // Up from the owner enters at the far end, not the near one.
    rt.focus = 30;
    const up = [_]elmz.Event{ .{ .key = .{ .named = .up } }, .quit };
    var fake3: Fake = .{ .events = &up };
    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake3.window(), .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(@as(?u64, 42), rt.focus);
}

var toast_clock: u64 = 0;
fn toastNow() u64 {
    toast_clock += 400 * std.time.ns_per_ms;
    return toast_clock;
}

fn toastView(s: *TState, ui: *elmz.Ui(TMsg)) *elmz.Element(TMsg) {
    const e = ui.text(.{ .label = "saved" });
    e.key = 70;
    if (s.n == 0) {
        e.widget = ui.payload(.{ .toast = .{ .ttl_ms = 1000, .msg = .inc } });
    }
    return e;
}

test "a toast expires on the clock with no input at all" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 120, 60);
    defer canvas.deinit();

    var rt = elmz.Runtime(TState, TMsg).init(gpa, .{}, tUpdate, toastView);
    defer rt.deinit();

    toast_clock = 0;
    // Nothing but time passes: the keys are ones the app ignores. Without the
    // shortened poll the loop would block forever and this would never fire.
    const events = [_]elmz.Event{
        .{ .key = .{ .code = 'a' } },
        .{ .key = .{ .code = 'b' } },
        .{ .key = .{ .code = 'c' } },
        .{ .key = .{ .code = 'd' } },
        .quit,
    };
    var fake: Fake = .{ .events = &events };
    _ = try run(struct {}, TState, TMsg, &rt, &canvas, fake.window(), .{
        .poll_timeout_ms = 0,
        .now_ns = &toastNow,
    });

    try std.testing.expectEqual(@as(i32, 1), rt.state.n);
}

test "a live toast shortens the poll, and a busy command still wins" {
    try std.testing.expectEqual(@as(i32, 100), effectiveTimeout(.{}, false, false, false, true));
    try std.testing.expectEqual(@as(i32, 50), effectiveTimeout(.{ .poll_timeout_ms = 50 }, false, false, false, true));
    try std.testing.expectEqual(@as(i32, 5), effectiveTimeout(.{}, true, false, false, true));
}

const PopState = struct {
    active: ?u16 = null,
    picked_b: u32 = 0,
    toggles: u32 = 0,
};
const PopMsg = enum { pick_a, pick_b, toggle };

fn popUpdate(s: *PopState, m: PopMsg) elmz.Action(PopMsg) {
    switch (m) {
        .pick_a => {},
        .pick_b => s.picked_b += 1,
        .toggle => s.toggles += 1,
    }
    return .{};
}

var pop_opts = [_]elmz.Choice(PopMsg){
    .{ .label = "alpha", .msg = .pick_a },
    .{ .label = "beta", .msg = .pick_b },
};

fn popView(s: *PopState, ui: *elmz.Ui(PopMsg)) *elmz.Element(PopMsg) {
    const field = ui.button(.{ .label = "choose", .msg = .toggle, .key = 60 });
    field.widget = ui.payload(.{ .select = .{
        .open = true,
        .selected = 0,
        .active = &s.active,
        .options = &pop_opts,
        .msg = .toggle,
    } });
    return ui.column(.{ .children = &.{field}, .width = 200, .height = 200 });
}

test "a press on an option chooses it, rather than dismissing the list" {
    const gpa = std.testing.allocator;
    var canvas = try testCanvas(gpa, 200, 200);
    defer canvas.deinit();

    var rt = elmz.Runtime(PopState, PopMsg).init(gpa, .{}, popUpdate, popView);
    defer rt.deinit();

    var probe = try rt.frame(.{ .w = 200, .h = 200 }, canvas.renderer());
    defer probe.deinit();

    // The row's own rectangle, taken from the hit list the frame actually
    // recorded rather than recomputed from the popup geometry: a test that
    // re-derives the box can only agree with itself.
    var beta: ?elmz.Rect = null;
    for (probe.hits) |h| {
        if (h.msg) |m| {
            if (m == .pick_b) beta = h.rect;
        }
    }
    try std.testing.expect(beta != null);

    // This is the ordering assertion. The scrim covers the whole window and
    // carries the toggle, so if it were appended AFTER the rows a press here
    // would close the list instead of choosing from it.
    const on_row: [2]f32 = .{ beta.?.x + beta.?.w / 2, beta.?.y + beta.?.h / 2 };
    const ev = [_]elmz.Event{ .{ .pointer_down = on_row }, .{ .pointer_up = on_row } };
    var fake: Fake = .{ .events = &ev, .w = 200, .h = 200 };
    _ = try run(struct {}, PopState, PopMsg, &rt, &canvas, fake.window(), .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(@as(u32, 1), rt.state.picked_b);
    try std.testing.expectEqual(@as(u32, 0), rt.state.toggles);

    // A press away from the list is the scrim's, and dismisses.
    const away: [2]f32 = .{ 195, 195 };
    const ev2 = [_]elmz.Event{ .{ .pointer_down = away }, .{ .pointer_up = away } };
    var fake2: Fake = .{ .events = &ev2, .w = 200, .h = 200 };
    _ = try run(struct {}, PopState, PopMsg, &rt, &canvas, fake2.window(), .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(@as(u32, 1), rt.state.toggles);
    try std.testing.expectEqual(@as(u32, 1), rt.state.picked_b);
}
