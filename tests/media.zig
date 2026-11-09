//! `.input`, `.icon` and `.image` in one frame, rendered headlessly.
//!
//! Three widgets whose sources are FILES rather than bytes, so the demo
//! generates its own fixtures at startup and then exercises the paths that
//! matter: an input that scrolls inside a fixed box, an icon tinted from the
//! theme, and a PNG drawn at its own aspect. Each is drawn twice -- before and
//! after an edit -- so the second frame proves the sources are served from
//! cache rather than re-read.

const std = @import("std");
const elmz = @import("elmz");
const software = @import("software");

pub const app = .{
    .title = "elmz - input, icon, image",
    .size = .{ .w = 520, .h = 420 },
    .Model = Model,
    .Msg = Msg,
    .update = update,
    .view = view,
    .on_text = onText,
    .on_key = onKey,
};

const W = app.size.w;
const H = app.size.h;
const key_box: u64 = 1;

pub const Msg = enum { focus_box, edited };
pub const Model = struct {
    box: elmz.TextEdit = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
};

pub fn update(m: *Model, msg: Msg) elmz.Action(Msg) {
    switch (msg) {
        .focus_box => return .{ .focus = .{ .set = key_box } },
        .edited => _ = m,
    }
    return .{};
}

fn onText(m: *Model, bytes: []const u8) ?Msg {
    const changed = m.box.typeBytes(m.arena.allocator(), bytes);
    return if (changed) .edited else null;
}

fn onKey(m: *Model, k: elmz.Key, phase: elmz.Phase) ?Msg {
    if (phase != .press) return null;
    const changed = m.box.handleKey(m.arena.allocator(), k);
    return if (changed) .edited else null;
}

const box_text =
    \\This box has a height of its own and does not
    \\grow. Type past the bottom and the text
    \\scrolls inside it, with the same wheel
    \\region and the same bar every other
    \\scrolling container uses -- because the
    \\offset lives in the runtime's per-path
    \\slot, not in the field.
    \\
    \\A fixed box is the point: a field that
    \\grew would push everything under it around
    \\while the user was still typing.
;

pub fn view(m: *Model, ui: *elmz.Ui(Msg)) *elmz.Element(Msg) {
    const th = ui.theme;

    const title = ui.text(.{ .label = "input · icon · image", .size = 20, .style = .{ .color = elmz.solid(th.text) } });

    // A box with a FIXED height, so the content above it overflows and scrolls.
    const field = ui.input(.{
        .key = key_box,
        .edit = &m.box,
        .size = 13,
        .msg = .focus_box,
        .height = 96,
        .style = .{
            .bg = elmz.solid(th.control),
            .border = elmz.solid(th.accent),
            .radius = 6,
        },
    });

    // An icon, tinted from the theme. The file is generated on disk at startup.
    const icon = ui.icon(.{
        .path = "frames/demo-icon.svg",
        .color = elmz.solid(th.accent),
        .width = 48,
        .height = 48,
    });

    // A raster, sized by its OWN header: 120x60, so a 120-wide box is 60 tall.
    // Nothing here states that ratio.
    const pic = ui.image(.{
        .path = "frames/demo-image.png",
        .width = 120,
    });

    const row = ui.row(.{
        .children = &.{ icon, pic },
        .gap = 16,
        .style = .{ .bg = elmz.solid(th.panel), .radius = 8, .pad = 12 },
    });

    return ui.column(.{
        .children = &.{ title, field, row },
        .gap = 14,
        .style = .{ .bg = elmz.solid(th.bg), .pad = 20 },
    });
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

const icon_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
    \\  <path d="M12 2 L22 20 L2 20 Z"/>
    \\</svg>
;

/// A PNG of `w`x`h`, every pixel `col`, deflate STORED so no compressor is
/// needed. Same shape `software.decodeStoredPng` reads.
fn writePng(io: std.Io, dir: std.Io.Dir, sub: []const u8, w: u32, h: u32, col: [4]u8, buf: []u8) !void {
    var n: usize = 0;
    const put = struct {
        fn f(out: []u8, at: *usize, tag: []const u8, data: []const u8) void {
            std.mem.writeInt(u32, out[at.*..][0..4], @intCast(data.len), .big);
            at.* += 4;
            @memcpy(out[at.*..][0..4], tag);
            at.* += 4;
            @memcpy(out[at.*..][0..data.len], data);
            at.* += data.len;
            var crc = std.hash.Crc32.init();
            crc.update(tag);
            crc.update(data);
            std.mem.writeInt(u32, out[at.*..][0..4], crc.final(), .big);
            at.* += 4;
        }
    }.f;

    @memcpy(buf[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    n = 8;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    put(buf, &n, "IHDR", &ihdr);

    var raw: [64 * 1024]u8 = undefined;
    var rn: usize = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        raw[rn] = 0;
        rn += 1;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            // A gradient across the width so the blit is visible as a picture
            // rather than a flat swatch.
            const k: u8 = @intCast((x * 255) / @max(w - 1, 1));
            @memcpy(raw[rn..][0..4], &[4]u8{ col[0], k / 2, col[2], 255 });
            rn += 4;
        }
    }

    var z: [128 * 1024]u8 = undefined;
    var zn: usize = 0;
    z[zn] = 0x78;
    z[zn + 1] = 0x01;
    zn += 2;
    var off: usize = 0;
    while (off < rn) {
        const take = @min(@as(usize, 65535), rn - off);
        z[zn] = if (off + take >= rn) 1 else 0;
        zn += 1;
        std.mem.writeInt(u16, z[zn..][0..2], @intCast(take), .little);
        zn += 2;
        std.mem.writeInt(u16, z[zn..][0..2], @intCast(~@as(u16, @intCast(take))), .little);
        zn += 2;
        @memcpy(z[zn..][0..take], raw[off..][0..take]);
        zn += take;
        off += take;
    }
    var a: u32 = 1;
    var b: u32 = 0;
    for (raw[0..rn]) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    std.mem.writeInt(u32, z[zn..][0..4], (b << 16) | a, .big);
    zn += 4;

    put(buf, &n, "IDAT", z[0..zn]);
    put(buf, &n, "IEND", &.{});
    try dir.writeFile(io, .{ .sub_path = sub, .data = buf[0..n] });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    const cwd = std.Io.Dir.cwd();
    cwd.createDir(io, "frames", .default_dir) catch {};
    try cwd.writeFile(io, .{ .sub_path = "frames/demo-icon.svg", .data = icon_svg });
    var png_buf: [200 * 1024]u8 = undefined;
    try writePng(io, cwd, "frames/demo-image.png", 120, 60, .{ 90, 120, 240, 255 }, &png_buf);

    // `initIo`, not `init`: an icon and an image READ THEIR FILE through the
    // canvas, and `init` leaves `io` null, which makes both fail silently --
    // the same "queued, never painted" shape the prim list would not reveal.
    var canvas = try software.Canvas.initIo(gpa, W, H, io);
    defer canvas.deinit();
    const font_bytes = software.loadFontByName(gpa, io, "DejaVu Sans", &.{}) catch null;
    defer if (font_bytes) |fb| gpa.free(fb);
    if (font_bytes) |fb| canvas.setFont(fb);

    var rt = elmz.Runtime(Model, Msg).init(gpa, .{}, update, view);
    defer rt.deinit();
    defer rt.state.arena.deinit();

    // Seed the box with more text than it can show, then render.
    _ = rt.state.box.insertText(rt.state.arena.allocator(), box_text);
    _ = rt.dispatch(.focus_box);

    var frame = try elmz.paintInto(Model, Msg, &rt, &canvas);
    defer frame.deinit();
    try report(out, &rt, &frame, 0, "seeded");
    try canvas.writePng(io, gpa, "frames/media-00-seeded.png");

    // SCROLL TO THE BOTTOM. Typing alone changes nothing visible: the new
    // bytes land past the fold and the clip (correctly) hides them, so a frame
    // that only types is pixel-identical to the one before it. The offset is
    // what moves the picture, and it lives in the runtime's per-path slot --
    // the same one the wheel writes through.
    // The scroll slot is keyed by PATH HASH, not by the element key: the
    // field is child 1 of the root column. Writing `key_box` here stores into
    // a slot nothing reads and the frame is pixel-identical.
    const field_slot = elmz.pathChild(elmz.scroll_path_root, 1);
    rt.scrollTo(field_slot, 9999); // clamped by `scrollFit` on read
    try out.print("    scroll offset after scrollTo: {d:.1}\n", .{rt.scrollOffset(field_slot)});
    var frame2 = try elmz.paintInto(Model, Msg, &rt, &canvas);
    defer frame2.deinit();
    try report(out, &rt, &frame2, 1, "scrolled");
    try canvas.writePng(io, gpa, "frames/media-01-scrolled.png");

    // The sources are deleted AFTER both frames: a third render that still
    // paints proves `.icon` and `.image` came from cache, not from disk.
    cwd.deleteFile(io, "frames/demo-icon.svg") catch {};
    cwd.deleteFile(io, "frames/demo-image.png") catch {};
    var frame3 = try elmz.paintInto(Model, Msg, &rt, &canvas);
    defer frame3.deinit();
    try report(out, &rt, &frame3, 2, "sources-deleted");
    try canvas.writePng(io, gpa, "frames/media-02-cached.png");

    try out.flush();
}

fn report(out: anytype, rt: anytype, frame: anytype, i: usize, what: []const u8) !void {
    try out.print(
        "frame {d} {s:<15} editing={} focus={?d} prims={d} hits={d}\n",
        .{ i, what, rt.text_editing, rt.focus, frame.primitiveCount(), frame.hits.len },
    );
    for (frame.prims) |pm| {
        switch (pm) {
            .quad => |q| try out.print("    quad  [{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{ q.rect.x, q.rect.y, q.rect.w, q.rect.h }),
            .rrect => |q| try out.print("    rrect [{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{ q.rect.x, q.rect.y, q.rect.w, q.rect.h }),
            .text => |t| try out.print("    text  [{d:.0},{d:.0}] \"{s}\"\n", .{ t.x, t.y, t.bytes }),
            .icon => |ic| try out.print("    icon  [{d:.0},{d:.0} {d:.0}x{d:.0}] {s}\n", .{ ic.rect.x, ic.rect.y, ic.rect.w, ic.rect.h, ic.path }),
            .image => |im| try out.print("    image [{d:.0},{d:.0} {d:.0}x{d:.0}] {s}\n", .{ im.rect.x, im.rect.y, im.rect.w, im.rect.h, im.path }),
            else => try out.print("    other\n", .{}),
        }
    }
    for (frame.hits) |h| {
        try out.print("    hit key={?d} scroll={} rect=[{d:.0},{d:.0} {d:.0}x{d:.0}]\n", .{
            h.key, h.scroll != null, h.rect.x, h.rect.y, h.rect.w, h.rect.h,
        });
    }
}
