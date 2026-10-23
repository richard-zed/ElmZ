//! The font system, rendered: the library ships no typeface, the app loads one,
//! and `Font` is a value rather than hidden global state.
//!
//! Writes two PNGs from the same view:
//!   fonts.png       -- the face loaded from disk
//!   fonts-none.png  -- no face: the built-in 5x6 diagnostic face draws the
//!                      same view. A missing typeface has to read as obviously
//!                      wrong legible text, never as a blank window -- a blank
//!                      window is the one answer that could pass for a bug.
//!
//!   zig build run-fonts

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");
const runner = @import("runner");

pub const app = .{
    .font_path = "src/font.ttf",
    .title = "elmz fonts",
    .size = .{ .w = 620, .h = 430 },
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

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    _ = m;
    const th = ui.theme;
    return ui.column(.{
        .children = &.{
            ui.text(.{ .label = "The library ships no typeface", .size = 27 }),
            ui.text(.{
                .label = "Font is a value. The app loads the file; nothing is compiled in.",
                .size = 13,
                .tone = .muted,
            }),
            ui.spaceBefore(ui.bar(.{ .value = 1 }), 16),

            ui.spaceBefore(ui.text(.{ .label = "34px  Handgloves", .size = 34 }), 20),
            ui.spaceBefore(ui.text(.{ .label = "24px  Handgloves", .size = 24 }), 12),
            ui.spaceBefore(ui.text(.{ .label = "18px  Handgloves", .size = 18 }), 10),
            ui.spaceBefore(ui.text(.{ .label = "14px  Handgloves", .size = 14 }), 8),
            ui.spaceBefore(ui.text(.{ .label = "11px  Handgloves", .size = 11, .tone = .muted }), 8),

            ui.spaceBefore(ui.text(.{
                .label = "0123456789 + - * / = ( ) [ ] { } % $ #",
                .size = 17,
            }), 18),
            ui.spaceBefore(ui.text(.{
                .label = "The quick brown fox jumps over the lazy dog.",
                .size = 17,
            }), 8),
            ui.spaceBefore(ui.text(.{
                .label = "MIXED case, muted tone, tabular-ish 1,234.56",
                .size = 17,
                .tone = .muted,
            }), 8),
            ui.spaceBefore(ui.text(.{
                .label = "rtl/arabic, CJK and emoji are NOT here yet -- one face, no fallback chain",
                .size = 12,
                .tone = .muted,
            }), 14),
        },
        .style = .{ .pad = 28, .bg = th.bg },
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);
    defer canvas.deinit();

    // The face, loaded at runtime. `loadFont` tries the path as given, then the
    // same basename beside the executable -- a binary in zig-out/bin finds its
    // font without depending on the launch directory.
    const bytes = try software.loadFont(gpa, io, "src/font.ttf");
    defer gpa.free(bytes);
    canvas.setFont(bytes);
    try out.print("loaded {d} bytes of typeface\n", .{bytes.len});

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();

    {
        var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer frame.deinit();
        try out.print("with a face:   {d} prims, {d} hits\n", .{ frame.primitiveCount(), frame.hits.len });
        try canvas.writePng(io, gpa, "fonts.png");
    }

    // Same view, no face. The built-in 5x6 face takes over, so the tree still
    // builds, layout does not explode and the app keeps running -- and the text
    // is legible but visibly not the app's typeface.
    canvas.setFont(&.{});
    {
        var frame = try runner.paintInto(Model, Msg, &rt, &canvas);
        defer frame.deinit();
        try out.print("without a face: {d} prims, {d} hits\n", .{ frame.primitiveCount(), frame.hits.len });
        try canvas.writePng(io, gpa, "fonts-none.png");
    }

    try out.flush();
}
