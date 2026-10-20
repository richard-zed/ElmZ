//! Software backend for elmz: an RGB framebuffer with a 5x7 bitmap font, plus a
//! dependency-free PNG encoder. This is the backend you want while you are
//! still arguing with layout; swap in a GPU backend later behind the same
//! `elmz.Renderer` vtable.

const std = @import("std");
const elmz = @import("elmz");
const ttf = @import("ttf.zig");
const Allocator = std.mem.Allocator;

pub const Canvas = struct {
    const Self = @This();

    gpa: Allocator,
    w: u32,
    h: u32,
    px: []u8, // RGBA8

    pub fn init(gpa: Allocator, w: u32, h: u32) !Self {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .gpa = gpa, .w = w, .h = h, .px = px };
    }

    pub fn deinit(self: *Self) void {
        self.gpa.free(self.px);
    }

    pub fn clear(self: *Self, color: elmz.Color) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            self.px[i + 0] = color.r;
            self.px[i + 1] = color.g;
            self.px[i + 2] = color.b;
            self.px[i + 3] = 255;
        }
    }

    fn blendPixel(self: *Self, x: i64, y: i64, color: elmz.Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.w or uy >= self.h) return;
        const i = (@as(usize, uy) * self.w + ux) * 4;
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        const dst_r: f32 = @floatFromInt(self.px[i + 0]);
        const dst_g: f32 = @floatFromInt(self.px[i + 1]);
        const dst_b: f32 = @floatFromInt(self.px[i + 2]);
        self.px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * a + dst_r * (1 - a));
        self.px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * a + dst_g * (1 - a));
        self.px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * a + dst_b * (1 - a));
    }

    const Span = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

    /// Integer pixel span of `rect` after clipping, or null when nothing is
    /// left. Both bounds are resolved before the loop, so the per-pixel path
    /// is exactly what it was when nothing clips.
    fn clipSpan(self: *Self, rect: elmz.Rect, clip: elmz.Rect) ?Span {
        // Edges are taken straight from the two rects rather than from
        // `intersect`, whose width is `x1 - x0`. That subtraction is not
        // always exact in f32, and re-deriving `x1` from it could move an
        // edge by one pixel. Copied this way, an unbounded clip reproduces
        // the unclipped arithmetic bit for bit.
        const cx0 = @max(rect.x, clip.x);
        const cy0 = @max(rect.y, clip.y);
        const cx1 = @min(rect.x + rect.w, clip.x + clip.w);
        const cy1 = @min(rect.y + rect.h, clip.y + clip.h);
        if (!(cx1 > cx0 and cy1 > cy0)) return null;
        const w_i: i64 = @intCast(self.w);
        const h_i: i64 = @intCast(self.h);
        const x0 = std.math.clamp(@as(i64, @intFromFloat(@floor(cx0))), 0, w_i);
        const y0 = std.math.clamp(@as(i64, @intFromFloat(@floor(cy0))), 0, h_i);
        const x1 = std.math.clamp(@as(i64, @intFromFloat(@ceil(cx1))), 0, w_i);
        const y1 = std.math.clamp(@as(i64, @intFromFloat(@ceil(cy1))), 0, h_i);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    pub fn fillRect(self: *Self, rect: elmz.Rect, fill: elmz.Fill) void {
        self.fillRectClip(rect, fill, elmz.Rect.unbounded);
    }

    pub fn fillRectClip(self: *Self, rect: elmz.Rect, fill: elmz.Fill, clip: elmz.Rect) void {
        const sp = self.clipSpan(rect, clip) orelse return;
        var y = sp.y0;
        switch (fill) {
            // The solid case hoists the colour out of the loop entirely: this
            // is still the path every plain background takes, and it must not
            // pay for gradients existing.
            .solid => |c| {
                if (c.a == 0) return;
                while (y < sp.y1) : (y += 1) {
                    var x = sp.x0;
                    while (x < sp.x1) : (x += 1) self.blendPixel(x, y, c);
                }
            },
            .linear => |g| {
                // A purely vertical axis makes the colour constant along every
                // scanline, so it is sampled once per ROW rather than per
                // pixel -- the row-wide fill survives untouched.
                if (g.to[1] != g.from[1] and g.to[0] == g.from[0]) {
                    const xm: f32 = @floatFromInt(sp.x0);
                    while (y < sp.y1) : (y += 1) {
                        const c = fill.colorAt(rect, xm, @as(f32, @floatFromInt(y)) + 0.5);
                        if (c.a == 0) continue;
                        var x = sp.x0;
                        while (x < sp.x1) : (x += 1) self.blendPixel(x, y, c);
                    }
                } else {
                    while (y < sp.y1) : (y += 1) {
                        const ym = @as(f32, @floatFromInt(y)) + 0.5;
                        var x = sp.x0;
                        while (x < sp.x1) : (x += 1) {
                            const c = fill.colorAt(rect, @as(f32, @floatFromInt(x)) + 0.5, ym);
                            if (c.a == 0) continue;
                            self.blendPixel(x, y, c);
                        }
                    }
                }
            },
            .radial => {
                while (y < sp.y1) : (y += 1) {
                    const ym = @as(f32, @floatFromInt(y)) + 0.5;
                    var x = sp.x0;
                    while (x < sp.x1) : (x += 1) {
                        const c = fill.colorAt(rect, @as(f32, @floatFromInt(x)) + 0.5, ym);
                        if (c.a == 0) continue;
                        self.blendPixel(x, y, c);
                    }
                }
            },
        }
    }

    fn scaleFor(size: f32) i64 {
        const s = @round(size / 7.0);
        return if (s < 1) 1 else @intFromFloat(s);
    }

    /// TrueType text, drawn by the same font that measured it.
    pub fn drawText(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8) void {
        self.drawTextClip(x, y, size, fill, bytes, elmz.Rect.unbounded);
    }

    pub fn drawTextClip(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        ttf.drawText(self.px, self.w, self.h, x, y, size, fill, bytes, clip);
    }

    /// The original 5x7 bitmap renderer, kept for tests and as the "no font"
    /// fallback path.
    pub fn drawTextBitmap(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8) void {
        const s = scaleFor(size);
        const bm = measureTextBitmap(bytes, size);
        const box: elmz.Rect = .{ .x = x, .y = y, .w = bm.width, .h = bm.height };
        const solid_c: ?elmz.Color = switch (fill) {
            .solid => |cc| cc,
            else => null,
        };
        var cursor: i64 = @intFromFloat(@floor(x));
        const top: i64 = @intFromFloat(@floor(y));
        for (bytes) |ch| {
            const rows = glyph(ch);
            for (rows, 0..) |row, ry| {
                const bits: u32 = row;
                var col: u5 = 0;
                while (col < 5) : (col += 1) {
                    const shift: u5 = 4 - col;
                    if ((bits >> shift) & 1 == 0) continue;
                    var dy: i64 = 0;
                    while (dy < s) : (dy += 1) {
                        var dx: i64 = 0;
                        while (dx < s) : (dx += 1) {
                            const px_x = cursor + @as(i64, col) * s + dx;
                            const px_y = top + @as(i64, @intCast(ry)) * s + dy;
                            self.blendPixel(px_x, px_y, solid_c orelse fill.colorAt(
                                box,
                                @as(f32, @floatFromInt(px_x)) + 0.5,
                                @as(f32, @floatFromInt(px_y)) + 0.5,
                            ));
                        }
                    }
                }
            }
            cursor += 6 * s;
        }
    }

    fn blendCoverage(self: *Self, x: i64, y: i64, color: elmz.Color, cov: f32) void {
        const a = cov * (@as(f32, @floatFromInt(color.a)) / 255.0);
        if (a <= 0) return;
        const i = (@as(usize, @intCast(y)) * self.w + @as(u32, @intCast(x))) * 4;
        const inv = 1.0 - a;
        self.px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * a + @as(f32, @floatFromInt(self.px[i + 0])) * inv);
        self.px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * a + @as(f32, @floatFromInt(self.px[i + 1])) * inv);
        self.px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * a + @as(f32, @floatFromInt(self.px[i + 2])) * inv);
    }

    /// Rounded rect by signed distance: the coverage of a pixel is derived
    /// from its distance to the rounded outline, which antialiases the curve
    /// and, with `stroke`, gives a 1px outline that follows it for free.
    pub fn roundRect(self: *Self, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool) void {
        self.roundRectClip(rect, radius, fill, stroke, elmz.Rect.unbounded);
    }

    pub fn roundRectClip(self: *Self, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool, clip: elmz.Rect) void {
        // The corner geometry comes from the unclipped rect on purpose: a clip
        // is a window over the shape, never a change to the shape.
        const r = @min(radius, @min(rect.w, rect.h) * 0.5);
        if (r <= 0) {
            if (!stroke) return self.fillRectClip(rect, fill, clip);
            // A solid square outline really is four quads, and emit draws it
            // that way. A GRADIENT one cannot be: each quad's box is 1px on
            // its short axis, so the ramp would restart per edge. Those fall
            // through to the SDF below with r = 0, which is a box.
            if (fill.isSolid()) return;
        }
        const hx = rect.w * 0.5 - r;
        const hy = rect.h * 0.5 - r;
        const cx = rect.x + rect.w * 0.5;
        const cy = rect.y + rect.h * 0.5;

        const sp = self.clipSpan(rect, clip) orelse return;

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                var cov = std.math.clamp(0.5 - d, 0, 1);
                if (stroke) cov -= std.math.clamp(0.5 - (d + 1.0), 0, 1);
                if (cov > 0) self.blendCoverage(x, y, fill.colorAt(
                    rect,
                    @as(f32, @floatFromInt(x)) + 0.5,
                    @as(f32, @floatFromInt(y)) + 0.5,
                ), cov);
            }
        }
    }

    /// Replay a recorded frame onto the pixels. `Runtime.frame` only records
    /// primitives; nothing is rasterised until this runs.
    pub fn paintFrame(self: *Self, prims: []const elmz.Primitive) void {
        const r = self.renderer();
        for (prims) |p| switch (p) {
            .quad => |q| r.quad(q.rect, q.fill, q.clip),
            .rrect => |q| r.roundedRect(q.rect, q.radius, q.fill, q.stroke, q.clip),
            .text => |t| r.text(t.x, t.y, t.size, t.fill, t.bytes, t.clip),
        };
    }

    /// Copy `src` into this canvas with its top-left at `at`.
    ///
    /// The 4-byte RGBA stride is this file's business, so callers should never
    /// restate it -- that is how the two previous hand-written copies of this
    /// loop ended up in example `main`s. Anything that would land outside the
    /// destination is dropped rather than erroring: compositing a contact sheet
    /// is the use, and a half-visible tile is more useful than a fatal error.
    pub fn blitFrom(self: *Self, src: *const Self, at: [2]u32) void {
        if (at[0] >= self.w or at[1] >= self.h) return;
        const copy_w: usize = @min(src.w, self.w - at[0]);
        const copy_h: usize = @min(src.h, self.h - at[1]);
        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            // usize throughout: w*h*4 overflows u32 on any canvas worth blitting.
            const dst_i = ((@as(usize, at[1]) + y) * self.w + at[0]) * 4;
            const src_i = (y * src.w) * 4;
            @memcpy(self.px[dst_i..][0 .. copy_w * 4], src.px[src_i..][0 .. copy_w * 4]);
        }
    }

    /// Encode to PNG and write it to the working directory.
    ///
    /// Every example wants exactly this, and the two-line version is easy to
    /// get subtly wrong: `encodePng` returns owned bytes that must survive
    /// until after the write.
    pub fn writePng(self: *const Self, io: std.Io, gpa: Allocator, name: []const u8) !void {
        const png = try self.encodePng(gpa);
        defer gpa.free(png);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = png });
    }

    pub fn measureText(bytes: []const u8, size: f32) elmz.TextMetrics {
        return ttf.measure(bytes, size);
    }

    pub fn wrapText(bytes: []const u8, size: f32, max_width: f32, out: [][]const u8) usize {
        return ttf.wrapLines(bytes, size, max_width, out);
    }

    pub fn measureTextBitmap(bytes: []const u8, size: f32) elmz.TextMetrics {
        const s = scaleFor(size);
        const n: i64 = @intCast(bytes.len);
        const h: f32 = @floatFromInt(7 * s);
        if (n == 0) return .{ .width = 0, .height = h, .ascent = h, .descent = 0, .line_height = h };
        return .{
            .width = @floatFromInt(n * 6 * s - s),
            .height = h,
            .ascent = h,
            .descent = 0,
            .line_height = h,
        };
    }

    // -- the elmz.Renderer vtable -------------------------------------------

    pub fn renderer(self: *Self) elmz.Renderer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = elmz.Renderer.VTable{
        .quad = vtQuad,
        .rrect = vtRrect,
        .text = vtText,
        .measure_text = vtMeasure,
        .wrap_text = vtWrap,
    };

    fn vtQuad(ptr: *anyopaque, rect: elmz.Rect, fill: elmz.Fill, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.fillRectClip(rect, fill, clip);
    }

    fn vtRrect(ptr: *anyopaque, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.roundRectClip(rect, radius, fill, stroke, clip);
    }

    fn vtText(ptr: *anyopaque, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.drawTextClip(x, y, size, fill, bytes, clip);
    }

    fn vtMeasure(ptr: *anyopaque, bytes: []const u8, size: f32) elmz.TextMetrics {
        _ = ptr;
        return measureText(bytes, size);
    }

    fn vtWrap(
        ptr: *anyopaque,
        bytes: []const u8,
        size: f32,
        max_width: f32,
        out: [][]const u8,
    ) usize {
        _ = ptr;
        return wrapText(bytes, size, max_width, out);
    }

    // -- PNG ----------------------------------------------------------------

    pub fn encodePng(self: *const Self, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const w = gpa;

        try out.appendSlice(w, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });

        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], self.w, .big);
        std.mem.writeInt(u32, ihdr[4..8], self.h, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // RGBA
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try writeChunk(w, &out, "IHDR", &ihdr);

        // raw scanlines with filter byte 0
        const stride: usize = @as(usize, self.w) * 4;
        var raw = try w.alloc(u8, (@as(usize, self.h)) * (stride + 1));
        defer w.free(raw);
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            const dst = @as(usize, y) * (stride + 1);
            raw[dst] = 0;
            @memcpy(raw[dst + 1 .. dst + 1 + stride], self.px[@as(usize, y) * stride ..][0..stride]);
        }

        const idat = try zlibStored(w, raw);
        defer w.free(idat);
        try writeChunk(w, &out, "IDAT", idat);
        try writeChunk(w, &out, "IEND", &.{});

        return out.toOwnedSlice(w);
    }

    fn writeChunk(gpa: Allocator, out: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, tag);
        try out.appendSlice(gpa, data);

        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(data);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
        try out.appendSlice(gpa, &crc_bytes);
    }

    /// zlib stream using stored (uncompressed) deflate blocks — no compressor
    /// dependency, valid PNG output.
    fn zlibStored(gpa: Allocator, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, &.{ 0x78, 0x01 });

        var off: usize = 0;
        while (true) {
            const chunk = @min(data.len - off, 65535);
            const is_final = off + chunk == data.len;
            try out.append(gpa, if (is_final) 0x01 else 0x00);
            var lens: [4]u8 = undefined;
            std.mem.writeInt(u16, lens[0..2], @intCast(chunk), .little);
            std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(chunk)), .little);
            try out.appendSlice(gpa, &lens);
            try out.appendSlice(gpa, data[off .. off + chunk]);
            off += chunk;
            if (is_final) break;
        }

        var adler_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &adler_bytes, std.hash.Adler32.hash(data), .big);
        try out.appendSlice(gpa, &adler_bytes);

        return out.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------------
// 5x7 font. MSB is the leftmost pixel.
// ---------------------------------------------------------------------------

fn glyph(ch: u8) [7]u5 {
    const c = std.ascii.toUpper(ch);
    return switch (c) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        '+' => .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        '=' => .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 },
        '.' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 },
        ':' => .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 },
        '%' => .{ 0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011 },
        '(' => .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
        ')' => .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
        '>' => .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 },
        '<' => .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 },
        ',' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00110, 0b00110, 0b00100 },
        '\'' => .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
        '_' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 },
        ';' => .{ 0b00000, 0b00110, 0b00110, 0b00000, 0b00110, 0b00110, 0b00100 },
        '?' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100 },
        '*' => .{ 0b00000, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0b00000 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

// ---------------------------------------------------------------------------
// the rasterizer, under test instead of under eyeball
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a quad covers exactly the pixels it names and nothing else" {
    var c = try Canvas.init(testing.allocator, 20, 20);
    defer c.deinit();

    c.fillRect(.{ .x = 5, .y = 5, .w = 10, .h = 10 }, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });

    var lit: usize = 0;
    for (0..20) |y| for (0..20) |x| {
        const i = (y * 20 + x) * 4;
        if (c.px[i] != 0) lit += 1;
    };
    try testing.expectEqual(@as(usize, 100), lit);
    // and it is the right 100: corners in, neighbours out
    const at = struct {
        fn f(px: []const u8, x: usize, y: usize) u8 {
            return px[(y * 20 + x) * 4];
        }
    }.f;
    try testing.expectEqual(@as(u8, 255), at(c.px, 5, 5));
    try testing.expectEqual(@as(u8, 255), at(c.px, 14, 14));
    try testing.expectEqual(@as(u8, 0), at(c.px, 4, 5));
    try testing.expectEqual(@as(u8, 0), at(c.px, 15, 14));
}

test "a quad larger than the canvas is clipped, not corrupting" {
    var c = try Canvas.init(testing.allocator, 8, 8);
    defer c.deinit();
    c.fillRect(.{ .x = -50, .y = -50, .w = 500, .h = 500 }, .{ .solid = .{ .r = 9, .g = 9, .b = 9, .a = 255 } });
    var i: usize = 0;
    while (i < c.px.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 9), c.px[i]);
        try testing.expectEqual(@as(u8, 9), c.px[i + 2]);
        try testing.expectEqual(@as(u8, 0), c.px[i + 3]); // alpha untouched
    }
}

test "text is really antialiased and its measure is not a guess" {
    var c = try Canvas.init(testing.allocator, 200, 40);
    defer c.deinit();
    c.drawText(2, 2, 20, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } }, "Hamburgefonstiv");

    var seen = std.AutoHashMap(u8, void).init(testing.allocator);
    defer seen.deinit();
    for (c.px) |b| try seen.put(b, {});

    // A bitmap font at integer scale yields 2 levels (0 and ink). Coverage
    // rasterisation yields a spread; if this drops to 2, the TTF path is dead.
    try testing.expect(seen.count() > 20);

    const m = Canvas.measureText("Hamburgefonstiv", 20);
    try testing.expect(m.width > 100 and m.width < 200);
    try testing.expect(m.height >= 20);
}

test "utf-8 is decoded, not measured as bytes" {
    const one = Canvas.measureText("日", 24);
    const three = Canvas.measureText("日本語", 24);
    try testing.expect(one.width > 8);
    // three copies of one glyph == one glyph measured three times
    try testing.expectApproxEqAbs(one.width * 3, three.width, 0.01);
    // and nothing like the 9 bytes it occupies
    try testing.expect(@abs(three.width - one.width * 9) > 1);
    // accented latin too: 'é' is two bytes, one glyph
    try testing.expectApproxEqAbs(
        Canvas.measureText("e", 20).width,
        Canvas.measureText("é", 20).width,
        0.01,
    );
}

test "wrapping breaks at spaces and loses nothing" {
    var buf: [8][]const u8 = undefined;
    const text = "the quick brown fox jumps";
    const n = Canvas.wrapText(text, 14, 60, &buf);
    try testing.expect(n >= 2);

    var joined: [64]u8 = undefined;
    var len: usize = 0;
    for (buf[0..n]) |line| {
        try testing.expect(Canvas.measureText(line, 14).width <= 60.5);
        if (len > 0) {
            joined[len] = ' ';
            len += 1;
        }
        @memcpy(joined[len..][0..line.len], line);
        len += line.len;
    }
    try testing.expectEqualStrings(text, joined[0..len]);
}

test "a single overlong word makes progress instead of looping" {
    var buf: [4][]const u8 = undefined;
    const n = Canvas.wrapText("antidisestablishmentarianism", 14, 40, &buf);
    try testing.expect(n >= 1 and n <= 4);
}

test "a wider budget produces fewer lines" {
    var a: [16][]const u8 = undefined;
    var b: [16][]const u8 = undefined;
    const text = "alpha beta gamma delta epsilon zeta";
    const narrow = Canvas.wrapText(text, 12, 50, &a);
    const wide = Canvas.wrapText(text, 12, 300, &b);
    try testing.expect(narrow > wide);
    try testing.expectEqual(@as(usize, 1), wide);
}

test "line height accounts for the font's line gap" {
    const m = Canvas.measureText("Ag", 20);
    // DejaVu declares a zero line gap, so spacing == height here. The field
    // exists because that is a property of the font, not a constant.
    try testing.expect(m.line_height >= m.height);
    try testing.expect(m.ascent > 0);
    try testing.expect(m.descent < 0);
}

// ---------------------------------------------------------------------------
// gradients: the numbers, not the vibes
// ---------------------------------------------------------------------------

fn chanAt(px: []const u8, w: u32, x: usize, y: usize) u8 {
    return px[(y * @as(usize, w) + x) * 4];
}

test "a vertical gradient ramps top to bottom and is constant across each row" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 40, 100);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 }); // green: anything unpainted shows up
    c.fillRect(.{ .x = 0, .y = 0, .w = 40, .h = 100 }, elmz.Fill.vgrad(
        elmz.Color.rgbHex(0x000000),
        elmz.Color.rgbHex(0xffffff),
    ));
    try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 0))), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 50))), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 99))), 3);
    // the per-row fast path is only correct if the colour really is row-constant
    try std.testing.expectEqual(chanAt(c.px, c.w, 1, 50), chanAt(c.px, c.w, 38, 50));
}

test "a horizontal gradient varies by column and not by row" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 100, 10);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 });
    c.fillRect(.{ .x = 0, .y = 0, .w = 100, .h = 10 }, elmz.Fill.hgrad(
        elmz.Color.rgbHex(0x000000),
        elmz.Color.rgbHex(0xffffff),
    ));
    try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(chanAt(c.px, c.w, 0, 5))), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(chanAt(c.px, c.w, 50, 5))), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(chanAt(c.px, c.w, 99, 5))), 3);
    try std.testing.expectEqual(chanAt(c.px, c.w, 50, 1), chanAt(c.px, c.w, 50, 8));
}

test "a radial fill is brightest at the centre and falls off outward" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 80, 80);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 });
    c.fillRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 }, elmz.Fill.radialFill(
        elmz.Color.rgbHex(0xffffff),
        elmz.Color.rgbHex(0x000000),
    ));
    const centre = chanAt(c.px, c.w, 40, 40);
    const edge = chanAt(c.px, c.w, 0, 0);
    try std.testing.expect(centre > 200);
    try std.testing.expect(edge < 60);
}

test "a gradient BORDER ramps around the outline and leaves the interior alone" {
    const gpa = std.testing.allocator;
    const bg = elmz.Color.rgbHex(0x102030);
    for ([_]f32{ 0, 14 }) |radius| {
        var c = try Canvas.init(gpa, 60, 60);
        defer c.deinit();
        c.clear(bg);
        c.roundRectClip(.{ .x = 10, .y = 10, .w = 40, .h = 40 }, radius, elmz.Fill.vgrad(
            elmz.Color.rgbHex(0xff0000),
            elmz.Color.rgbHex(0x0000ff),
        ), true, elmz.Rect.unbounded);
        // top edge is the ramp's start, bottom edge its end
        const top = c.px[((10 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        const bot = c.px[((49 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        try std.testing.expect(top[0] > 150 and top[2] < 100);
        try std.testing.expect(bot[2] > 150 and bot[0] < 100);
        // interior untouched: a stroke must not fill the shape
        const mid = c.px[((30 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        try std.testing.expectEqual(bg.r, mid[0]);
        try std.testing.expectEqual(bg.g, mid[1]);
        try std.testing.expectEqual(bg.b, mid[2]);
    }
}

test "text takes a gradient fill, not just a solid colour" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 240, 48);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 0, .b = 0 });
    c.drawText(2, 2, 30, elmz.Fill.hgrad(
        elmz.Color.rgbHex(0xff0000),
        elmz.Color.rgbHex(0x0000ff),
    ), "MMMMMMMM");

    // Inked span, so the test follows the glyphs instead of assuming where
    // they landed.
    var first: ?usize = null;
    var last: usize = 0;
    var inked: usize = 0;
    var x: usize = 0;
    while (x < c.w) : (x += 1) {
        var y: usize = 0;
        while (y < c.h) : (y += 1) {
            const p = c.px[(y * @as(usize, c.w) + x) * 4 ..][0..3];
            if (p[0] > 40 or p[2] > 40) {
                inked += 1;
                if (first == null) first = x;
                last = x;
            }
        }
    }
    try std.testing.expect(inked > 200);

    const f = first.?;
    const span = last - f;
    const third = @max(@as(usize, 1), span / 3);

    // Means, not extremes: the ramp's endpoints are pure red and pure blue, so
    // the MAX of each channel is ~255 at both ends and compares nothing.
    var lr: usize = 0;
    var lb: usize = 0;
    var ln: usize = 0;
    var rr: usize = 0;
    var rb: usize = 0;
    var rn: usize = 0;
    x = f;
    while (x <= last) : (x += 1) {
        var y: usize = 0;
        while (y < c.h) : (y += 1) {
            const p = c.px[(y * @as(usize, c.w) + x) * 4 ..][0..3];
            if (p[0] <= 40 and p[2] <= 40) continue; // background
            if (x < f + third) {
                lr += p[0];
                lb += p[2];
                ln += 1;
            } else if (x > last - third) {
                rr += p[0];
                rb += p[2];
                rn += 1;
            }
        }
    }
    try std.testing.expect(ln > 0 and rn > 0);
    const left_red = lr / ln;
    const right_red = rr / rn;
    const left_blue = lb / ln;
    const right_blue = rb / rn;
    // The ramp must actually run ACROSS the run, not restart per glyph.
    try std.testing.expect(left_red > right_red + 20);
    try std.testing.expect(right_blue > left_blue + 20);
}
