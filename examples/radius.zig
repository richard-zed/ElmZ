//! Corner radii: a grid of fills and outlines at increasing radius, plus one
//! rounded container with text inside it. Headless — writes radius.png.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

const Model = struct {};
const Msg = enum {};

fn update(_: *Model, _: Msg) elmz.Action(Msg) {
    return .{};
}

/// The app declaration the window composition binds to. The headless `main`
/// below builds its own Runtime from the same three functions, so the picture
/// and the window cannot drift: one `view`, two ways to drive it.
pub const app = .{
    .title = "elmz - corner radii",
    .size = .{ .w = 420, .h = 320 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
};

fn cards(ui: *elmz.Ui(Msg), filled: bool) *elmz.Element(Msg) {
    const radii = [_]f32{ 0, 3, 6, 14, 28 };
    var items: [radii.len]*elmz.Element(Msg) = undefined;
    for (radii, 0..) |rad, i| {
        const c = ui.rect(.{ .width = 56, .height = 56, .style = .{
            .radius = rad,
            .bg = if (filled) ui.theme.control else null,
            .border = if (filled) null else ui.theme.accent,
        } });
        items[i] = c;
    }
    const row = ui.row(.{ .children = &items, .gap = 14 });
    return row;
}

fn view(_: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const caption = ui.text(.{ .label = "the same 1px outline follows the curve instead of four quads", .size = 10, .tone = .muted, .wrap = true });
    // the card holds the paragraph to 300, which is what the paragraph used to
    // be told directly; now the container's width is the only place it can come
    // from, so the two cannot disagree
    const inner = ui.column(.{ .children = &.{
        ui.text(.{ .label = "radius", .size = 18 }),
        caption,
    }, .width = 300 + 2 * 14, .gap = 6, .style = .{ .pad = 14, .bg = ui.theme.panel, .border = ui.theme.text_muted, .radius = 18 } });

    const line0 = cards(ui, true);
    line0.margin_top = 4;
    const line1 = cards(ui, false);
    line1.margin_top = 6;
    inner.margin_top = 10;
    const col = ui.column(.{ .children = &.{
        ui.text(.{ .label = "corner radii", .size = 22 }),
        line0,
        line1,
        inner,
    }, .gap = 4, .style = .{ .pad = 24, .bg = ui.theme.bg } });
    return col;
}

pub fn main(init: std.process.Init) !void {
    // `start.zig` has already built the general purpose allocator (leak checking
    // included, in Debug) and the IO runtime. Constructing our own only
    // duplicated them -- this is where five copies of `std.Io.Threaded.init`
    // came from, in a program that never wanted a thread.
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, 380, 330);

    // Caller-owned bytes: the canvas holds a slice into them, so the
    // free is registered first and therefore runs after the teardown.
    // By NAME, the way an app names a face in its theme: whichever face this
    // machine has, or none. With no fonts installed every example still runs and
    // the text falls back to the built-in bitmap face.
    const font_bytes = software.loadFontByName(gpa, init.io, "DejaVu Sans", &.{}) catch null;
    defer if (font_bytes) |fb| gpa.free(fb);
    if (font_bytes) |fb| canvas.setFont(fb);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
    defer frame.deinit();

    try canvas.writePng(io, gpa, "radius.png");

    var rr: usize = 0;
    for (frame.prims) |p| switch (p) {
        .rrect => rr += 1,
        else => {},
    };
    try out.print("wrote radius.png: {d} primitives, {d} rounded\n", .{ frame.prims.len, rr });
    try out.flush();
}
