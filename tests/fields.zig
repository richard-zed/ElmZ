//! A form, driven headlessly: two text fields, one of them masked.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");

pub const app = .{
    .title = "fields",
    .size = .{ .w = 380, .h = 230 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    .on_text = onText,
    .on_key = onKey,
};

const W = app.size.w;
const H = app.size.h;

const key_name = 1;
const key_pass = 2;

pub const Msg = enum { focus_name, focus_pass, edited };

/// Which field the keyboard is going into. The runtime knows it too, but the reducer needs
/// it and a hook is given only the Model.
const Target = enum { name, pass };

pub const Model = struct {
    name: elmz.TextEdit = .{},
    pass: elmz.TextEdit = .{},
    target: Target = .name,
    edits: u32 = 0,
    /// Bytes a keystroke produces must outlive the frame that produced them, so they cannot
    /// come from `Ui`'s per-frame arena.
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        // `dispatch` applies the focus change to the runtime itself, so the
        // app names the field here and never writes `rt.focus` by hand.
        .focus_name => {
            m.target = .name;
            return .{ .focus = .{ .set = key_name } };
        },
        .focus_pass => {
            m.target = .pass;
            return .{ .focus = .{ .set = key_pass } };
        },
        .edited => m.edits += 1,
    }
    return .{};
}

fn field(m: *Model) *elmz.TextEdit {
    return switch (m.target) {
        .name => &m.name,
        .pass => &m.pass,
    };
}

/// Typed bytes. Returning a message is how the frame gets marked dirty -- a hook that
/// returns null has changed the Model and told nobody.
pub fn onText(m: *Model, bytes: []const u8) ?Msg {
    if (field(m).typeBytes(m.arena.allocator(), bytes)) return .edited;
    return null;
}

pub fn onKey(m: *Model, k: elmz.keys.Key) ?Msg {
    if (field(m).handleKey(m.arena.allocator(), k)) return .edited;
    return null;
}

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const line0 = ui.text(.{ .label = ui.fmt("{d} edit(s), {d} name byte(s), {d} secret byte(s)", .{
        m.edits, m.name.value.len, m.pass.value.len,
    }), .size = 12 });
    line0.margin_top = 14;
    return ui.column(.{
        .children = &.{
            ui.text(.{ .label = "NAME", .size = 11, .tone = .muted }),
            ui.textInput(.{
                .key = key_name,
                .edit = &m.name,
                .size = 16,
                .width = 320,
                .msg = .focus_name,
                .placeholder = "your name",
            }),
            ui.text(.{ .label = "PASSPHRASE", .size = 11, .tone = .muted, .margin_top = 12 }),
            // `mask` builds a display string of one `?` per codepoint in the
            // BUILDER, so the caret is placed and drawn in the same units.
            ui.textInput(.{
                .key = key_pass,
                .edit = &m.pass,
                .size = 16,
                .width = 320,
                .mask = true,
                .msg = .focus_pass,
                .placeholder = "secret",
            }),
            line0,
        },
        .style = .{ .pad = 18 },
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var canvas = try software.Canvas.init(gpa, W, H);
    const font_bytes = software.loadFontByName(gpa, io, "DejaVu Sans", &.{}) catch null;
    defer if (font_bytes) |fb| gpa.free(fb);
    if (font_bytes) |fb| canvas.setFont(fb);
    defer canvas.deinit();

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();
    // The arena is the Model's, so it dies with the Model, not with a frame.
    defer rt.state.arena.deinit();

    // A window backend would deliver these; the script stands in for it, and
    // goes through the same hooks the runner calls.
    const typed = "abel";
    var i: usize = 0;
    for (typed) |c| {
        if (onText(&rt.state, &.{c})) |msg| _ = rt.dispatch(msg);
        var frame = try elmz.paintInto(Model, Msg, &rt, &canvas);
        try snap(io, gpa, out, &rt, &canvas, &frame, i, "type");
        frame.deinit();
        i += 1;
    }

    // Focus starts on the name field, the way a click on it would leave it.
    _ = rt.dispatch(.focus_name);

    // ...and moves to the secret field: again a message, not a write.
    _ = rt.dispatch(.focus_pass);

    for ("hunter2") |c| {
        if (onText(&rt.state, &.{c})) |msg| _ = rt.dispatch(msg);
        var frame = try elmz.paintInto(Model, Msg, &rt, &canvas);
        try snap(io, gpa, out, &rt, &canvas, &frame, i, "type");
        frame.deinit();
        i += 1;
    }

    // Backspace once: the last `2` goes, and the caret follows the text.
    const back: elmz.keys.Key = .{ .named = .backspace };
    if (onKey(&rt.state, back)) |msg| _ = rt.dispatch(msg);
    var frame = try elmz.paintInto(Model, Msg, &rt, &canvas);
    try snap(io, gpa, out, &rt, &canvas, &frame, i, "backspace");
    frame.deinit();

    try out.print("\nname = \"{s}\" (caret {d})\n", .{ rt.state.name.value, rt.state.name.caret });
    try out.print("pass = \"{s}\" (caret {d}) -- drawn as '?' per codepoint\n", .{
        rt.state.pass.value, rt.state.pass.caret,
    });
    try out.flush();
}

fn snap(io: anytype, gpa: anytype, out: anytype, rt: anytype, canvas: anytype, frame: anytype, i: usize, what: []const u8) !void {
    try report(out, rt, frame, i, what);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "frames/{d:0>2}-{s}.png", .{ i, what });
    try canvas.writePng(io, gpa, name);
}

fn report(out: anytype, rt: anytype, frame: anytype, i: usize, what: []const u8) !void {
    try out.print("frame {d:<2} {s:<9} editing={}  focus={?d}  prims={d}  hits={d}\n", .{
        i, what, rt.text_editing, rt.focus, frame.primitiveCount(), frame.hits.len,
    });
    for (frame.prims) |pm| {
        switch (pm) {
            .quad => |q| try out.print("    prim quad [{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{ q.rect.x, q.rect.y, q.rect.w, q.rect.h }),
            .rrect => |q| try out.print("    prim rrect [{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{ q.rect.x, q.rect.y, q.rect.w, q.rect.h }),
            .text => |t| try out.print("    prim text [{d:.0},{d:.0}] \"{s}\"\n", .{ t.x, t.y, t.bytes }),
            else => try out.print("    prim other\n", .{}),
        }
    }
    for (frame.hits) |h| {
        try out.print("    hit key={?d} widget={} rect=[{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{
            h.key, h.widget != null, h.rect.x, h.rect.y, h.rect.w, h.rect.h,
        });
    }
}
