//! Six languages, one frame, everything named in `theme.defaults.zon`. The point is that NO
//! font name appears in this file.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .title = "elmz languages",
    .size = .{ .w = 720, .h = 620 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

const W = app.size.w;
const H = app.size.h;

pub const Msg = enum { noop };
pub const Model = struct {};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    _ = m;
    _ = msg;
    return .{};
}

/// One row: the language's own name in its own script, plus what it is in English so a
/// reader who cannot see the script can still tell them apart.
const Row = struct { style: []const u8, label: []const u8, said: []const u8 };

const rows = [_]Row{
    .{ .style = "latin", .label = "Français", .said = "Bonjour tout le monde" },
    .{ .style = "arabic", .label = "العربية", .said = "السلام عليكم" },
    .{ .style = "thai", .label = "ไทย", .said = "สวัสดีครับ" },
    .{ .style = "chinese", .label = "中文", .said = "你好世界" },
    .{ .style = "japanese", .label = "日本語", .said = "こんにちは世界" },
    .{ .style = "korean", .label = "한국어", .said = "안녕하세요 세계" },
};

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    _ = m;
    var kids: [32]*elmz.Element(Msg) = undefined;
    var n: usize = 0;

    kids[n] = ui.text(.{ .label = "Six languages, named in theme.defaults.zon", .size = 22 });
    n += 1;
    kids[n] = ui.text(.{
        // The caption itself is a plain label. If NO .styles were loaded this
        // table would be empty and every row would fall back to the primary
        // face -- visibly wrong, rather than quietly right by accident.
        .label = if (ui.styles == null) "no theme styles loaded" else "styles resolved from the theme file",
        .size = 12,
        .tone = .muted,
        .margin_bottom = 6,
    });
    n += 1;

    for (rows) |r| {
        // The ONLY input is the style name.
        const st = ui.styleByName(r.style) orelse elmz.Style{};
        kids[n] = ui.text(.{
            .label = r.label,
            .size = 13,
            .tone = .muted,
            .style = st,
            .margin_top = 14,
        });
        n += 1;
        const body = ui.text(.{
            .label = r.said,
            .size = 30,
            .style = st,
            .margin_top = 2,
        });
        kids[n] = body;
        n += 1;
    }

    kids[n] = ui.text(.{
        .label = "Chinese, Japanese and Korean are three indices into ONE collection file.",
        .size = 11,
        .tone = .muted,
        .margin_top = 22,
    });
    n += 1;

    return ui.column(.{ .children = kids[0..n], .margin_left = 26, .margin_top = 22, .gap = 2 });
}

pub fn main(init: std.process.Init) !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const gpa = da.allocator();
    const io = init.io;

    // Caller-owned buffer, like every other example. Passing `&.{}` made the
    // writer allocate its own and never free it, so DebugAllocator reported a
    // leak at exit -- which reads as a crash AFTER a successful render.
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    // NO `defer out.flush()`. `paint.zig` omits it and does not leak; adding it
    // here produced the leak, because `sendFile` grows a HEAP buffer via
    // `ensureTotalCapacity` when the payload exceeds `buf`, and the writer has
    // no `deinit` to release it. The explicit flush at the end of `main` is the
    // only one needed, and it runs while the writer is still alive.

    var canvas = try software.Canvas.init(gpa, W, H);
    defer canvas.deinit();

    // The primary face. Everything else arrives by NAME through the registry,
    // exactly as the theme file wrote it.
    const primary: ?[]u8 = software.loadFontByName(gpa, io, "DejaVu Sans", &.{}) catch null;
    defer if (primary) |b| gpa.free(b);
    if (primary) |b| canvas.setFont(b);

    const fonts = runner.HeadlessFonts.init(gpa, io, null);
    defer fonts.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    // Load through the CHAIN, not the loader: the chain owns the conversion
    // from the file's style entries to the view's, so an example never has to
    // know both types exist.
    // The BASE PATH matters: passing null here reads no file at all, leaves
    // `.styles` empty, and every row silently falls back to the primary face --
    // which renders tofu for every script but Latin, and looks like a font bug
    // rather than a wiring one.
    // Passing null here reads NO file: `.styles` comes back empty, every row
    // falls through to the primary face, and every non-Latin script renders as
    // tofu. That failure is silent -- the pixels are still ink, so counting ink
    // proves nothing. The path is the whole point.
    const base: ?[:0]u8 = runner.themePathBesideExe(gpa, io, "theme.defaults.zon");
    defer if (base) |b| gpa.free(b);
    // The USER file too, which this used to pass as null. Missing it meant the
    // example read only `theme.defaults.zon`, so an edit to `theme.zon` changed
    // nothing here and looked like the style system ignoring the file. Null is
    // still the right answer when the file is absent -- resolveChain treats a
    // null path as "no override", not as an error.
    const user: ?[:0]u8 = runner.themePathBesideExe(gpa, io, "theme.zon");
    defer if (user) |u| gpa.free(u);
    // The app tier. `theme.zon` carries `.vars = .{ .weight = 600, .latin_font =
    // "Roboto Flex" }`, and an app that declares nothing REJECTS `.vars` -- a
    // structural refusal, not a warning, because `ignore_unknown_fields` is
    // file-wide and would also swallow typos in `.colors`. Declaring the vars
    // here is what lets the example's own theme.zon load at all.
    const App = struct {
        weight: ?u16 = null,
        latin_font: ?[]const u8 = null,
    };
    var chain = runner.resolveChain(App, gpa, io, rt.ui.theme, base, user);
    defer chain.deinit(gpa);
    rt.ui.theme = chain.theme;
    rt.ui.gradients = chain.gradients;
    // Keep the COMPILED table when no file supplied one. Assigning null here
    // would discard `elmz.default_styles` and put the example back to the state
    // where `heading` and every script resolved to nothing.
    rt.ui.styles = if (chain.styles.len > 0) chain.styles else elmz.default_styles;
    if (chain.message()) |m| try out.print("theme: {s}\n", .{m});
    try out.print("theme: {d} styles\n", .{chain.styles.len});

    // FORCE every style's face into the registry BEFORE attaching. A style holds
    // a font NAME, not a loaded face: nothing resolves it until something asks,
    // and `attachAll` only registers what is already there. Attaching first --
    // the obvious order -- registers only the faces loaded so far, and every
    // styled label silently paints in the default face. That is what made Thai
    // and CJK tofu while the styles all reported "ok".
    //
    // Through the REGISTRY, not `rt.ui.font`: `ui.face_lookup` is mirrored at
    // the top of a frame, so calling the Ui's resolver out here finds a null
    // handle and reports every face missing, including DejaVu.
    for (rt.ui.styles orelse &.{}) |st| {
        if (st.spec.font) |fname| {
            const got = fonts.reg.indexOf(fname);
            try out.print("  face {s}: {s}\n", .{ fname, if (got != null) "loaded" else "MISSING" });
        }
    }
    fonts.attach(Model, Msg, &rt, &canvas);

    // Report what each style resolved to, so a missing face is visible in the
    // log rather than as a blank line in the PNG.
    for (rows) |r| {
        try out.print("{s:10} {s}\n", .{ r.style, if (rt.ui.styleByName(r.style) != null) "ok" else "MISSING" });
    }

    {
        var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer frame.deinit();
        try out.print("{d} prims\n", .{frame.primitiveCount()});
        try canvas.writePng(io, gpa, "languages.png");
    }

    out.flush() catch {};
}
