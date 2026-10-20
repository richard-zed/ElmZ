//! TrueType text: glyph metrics and rasterisation via stb_truetype.
//!
//! There is no embedded font here. A `Font` is a value the caller creates from
//! bytes it owns, and every metric and every glyph comes from that same
//! `stbtt_fontinfo` -- which is why layout and paint agree, the bug class this
//! module exists to avoid. Keeping the face out of the library means the
//! library ships no typeface and no licence question with it.
//!
//! `Font` borrows the bytes: stb_truetype holds pointers into them for as long
//! as the font is used, so they must outlive it.

const std = @import("std");
const elmz = @import("elmz");

pub const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// Vertical metrics of one line, in pixels.
pub const V = struct { ascent: f32, descent: f32, line_gap: f32 };

/// One loaded face. `none` is a font that failed to load: it measures at zero
/// and draws nothing, so a missing file degrades to invisible text rather than
/// a crash or a silent fallback to different glyphs.
pub const Font = struct {
    info: c.stbtt_fontinfo = undefined,
    ok: bool = false,

    pub const none: Font = .{};

    /// Borrow `bytes`. They must outlive every use of the returned font.
    pub fn init(bytes: []const u8) Font {
        var f: Font = .{};
        if (bytes.len == 0) return f;
        const off = c.stbtt_GetFontOffsetForIndex(bytes.ptr, 0);
        if (off < 0) return f;
        if (c.stbtt_InitFont(&f.info, bytes.ptr, off) == 0) return f;
        f.ok = true;
        return f;
    }

    pub fn verticalMetrics(self: *const Font, size: f32) V {
        if (!self.ok) return .{ .ascent = size, .descent = 0, .line_gap = 0 };
        const s = c.stbtt_ScaleForPixelHeight(&self.info, size);
        var a: c_int = 0;
        var d: c_int = 0;
        var g: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &a, &d, &g);
        return .{
            .ascent = @as(f32, @floatFromInt(a)) * s,
            .descent = @as(f32, @floatFromInt(d)) * s,
            .line_gap = @as(f32, @floatFromInt(g)) * s,
        };
    }

    pub fn measure(self: *const Font, bytes: []const u8, size: f32) elmz.TextMetrics {
        const v = self.verticalMetrics(size);
        if (!self.ok) return .{
            .width = 0,
            .height = size,
            .ascent = size,
            .descent = 0,
            .line_height = size,
        };
        const f = &self.info;
        const s = c.stbtt_ScaleForPixelHeight(f, size);
        var w: f32 = 0;
        var prev: c_int = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = decode(bytes, &i);
            if (cp == '\n') continue; // a newline is not ink
            w += advanceOf(f, s, &prev, @intCast(cp));
        }
        return .{
            .width = w,
            .height = v.ascent - v.descent,
            .ascent = v.ascent,
            .descent = v.descent,
            .line_height = v.ascent - v.descent + v.line_gap,
        };
    }

    /// Greedy line breaking. Splits on spaces and on explicit newlines, and
    /// never returns a zero-length slice in the middle of a string. Returns the
    /// count, bounded by `out.len`.
    pub fn wrapLines(self: *const Font, bytes: []const u8, size: f32, max_w: f32, out: [][]const u8) usize {
        if (out.len == 0) return 0;
        const f: ?*const c.stbtt_fontinfo = if (self.ok) &self.info else null;
        const s = if (f) |ff| c.stbtt_ScaleForPixelHeight(ff, size) else 1.0;
        const fallback: f32 = 6 * size / 10;

        var n: usize = 0;
        var start: usize = 0;
        while (true) {
            if (start >= bytes.len) {
                out[n] = bytes[start..];
                return n + 1;
            }
            var i = start;
            var w: f32 = 0;
            var prev: c_int = 0;
            var break_end = bytes.len;
            var break_next = bytes.len;
            var last_space: ?usize = null;

            while (i < bytes.len) {
                const at = i;
                const cp = decode(bytes, &i);
                if (cp == '\n') {
                    break_end = at;
                    break_next = i;
                    break;
                }
                if (cp == ' ') last_space = at;
                if (f) |ff| {
                    w += advanceOf(ff, s, &prev, @intCast(cp));
                } else w += fallback;
                if (w > max_w and at > start) {
                    if (last_space) |sp| {
                        break_end = sp;
                        break_next = sp + 1;
                    } else {
                        break_end = at;
                        break_next = i;
                    }
                    break;
                }
            }

            out[n] = bytes[start..break_end];
            n += 1;
            if (break_next >= bytes.len or n >= out.len) return n;
            start = break_next;
        }
    }

    /// `y` is the top of the line box; the baseline is derived from the font.
    /// `clip` is the window glyphs are confined to. It is turned into integer
    /// bounds once, then tested per glyph pixel next to the existing canvas
    /// bounds checks -- so clipping text costs a comparison per pixel, not a
    /// second pass.
    pub fn drawText(
        self: *const Font,
        px: []u8,
        cw: u32,
        ch: u32,
        x: f32,
        y: f32,
        size: f32,
        fill: elmz.Fill,
        bytes: []const u8,
        clip: elmz.Rect,
    ) void {
        if (!self.ok) return;
        const f = &self.info;
        // The gradient's reference box is the line box this text occupies, so a
        // vertical ramp runs over one line, not the whole window.
        const tm = self.measure(bytes, size);
        const box: elmz.Rect = .{ .x = x, .y = y, .w = tm.width, .h = tm.height };
        const solid_c: ?elmz.Color = switch (fill) {
            .solid => |cc| cc,
            else => null,
        };
        const cx0: i64 = @intFromFloat(@floor(clip.x));
        const cy0: i64 = @intFromFloat(@floor(clip.y));
        const cx1: i64 = @intFromFloat(@ceil(clip.x + clip.w));
        const cy1: i64 = @intFromFloat(@ceil(clip.y + clip.h));
        const s = c.stbtt_ScaleForPixelHeight(f, size);
        const baseline = y + self.verticalMetrics(size).ascent;
        var pen = x;
        var prev: c_int = 0;
        var idx: usize = 0;
        while (idx < bytes.len) {
            const cp: c_int = @intCast(decode(bytes, &idx));
            if (cp == '\n') continue;
            if (prev != 0) pen += @as(f32, @floatFromInt(c.stbtt_GetCodepointKernAdvance(f, prev, cp))) * s;

            var gw: c_int = 0;
            var gh: c_int = 0;
            var gx: c_int = 0;
            var gy: c_int = 0;
            const bmp = c.stbtt_GetCodepointBitmap(f, s, s, cp, &gw, &gh, &gx, &gy);
            if (bmp != null and gw > 0 and gh > 0) {
                const ox: i64 = @intFromFloat(@round(pen + @as(f32, @floatFromInt(gx))));
                const oy: i64 = @intFromFloat(@round(baseline + @as(f32, @floatFromInt(gy))));
                var row: c_int = 0;
                while (row < gh) : (row += 1) {
                    const py = oy + row;
                    if (py < cy0 or py >= cy1) continue;
                    var col: c_int = 0;
                    while (col < gw) : (col += 1) {
                        const gx_px = ox + @as(i64, col);
                        if (gx_px < cx0 or gx_px >= cx1) continue;
                        const cov = bmp[@as(usize, @intCast(row * gw + col))];
                        if (cov != 0) blend(px, cw, ch, gx_px, py, solid_c orelse fill.colorAt(
                            box,
                            @as(f32, @floatFromInt(gx_px)) + 0.5,
                            @as(f32, @floatFromInt(py)) + 0.5,
                        ), cov);
                    }
                }
                c.stbtt_FreeBitmap(bmp, null);
            }

            pen += advanceOf(f, s, &prev, cp);
        }
    }
};

/// One codepoint from UTF-8. Malformed input yields U+FFFD and consumes one
/// byte, so a bad string degrades to boxes instead of a crash or a loop.
pub fn decode(bytes: []const u8, i: *usize) u32 {
    const b = bytes[i.*];
    if (b < 0x80) {
        i.* += 1;
        return b;
    }
    const len: usize = if ((b & 0xE0) == 0xC0) 2 else if ((b & 0xF0) == 0xE0) 3 else if ((b & 0xF8) == 0xF0) 4 else {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > bytes.len) {
        i.* = bytes.len;
        return 0xFFFD;
    }
    var cp: u32 = switch (len) {
        2 => @as(u32, b & 0x1F),
        3 => @as(u32, b & 0x0F),
        else => @as(u32, b & 0x07),
    };
    var k: usize = 1;
    while (k < len) : (k += 1) {
        const cont = bytes[i.* + k];
        if ((cont & 0xC0) != 0x80) {
            i.* += 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | @as(u32, cont & 0x3F);
    }
    i.* += len;
    return cp;
}

/// Advance of one codepoint in pixels, kerning against `prev` folded in.
fn advanceOf(f: *const c.stbtt_fontinfo, s: f32, prev: *c_int, cp: c_int) f32 {
    var adv: c_int = 0;
    var lsb: c_int = 0;
    var w: f32 = 0;
    if (prev.* != 0) w += @as(f32, @floatFromInt(c.stbtt_GetCodepointKernAdvance(f, prev.*, cp))) * s;
    c.stbtt_GetCodepointHMetrics(f, cp, &adv, &lsb);
    prev.* = cp;
    return w + @as(f32, @floatFromInt(adv)) * s;
}

fn blend(px: []u8, cw: u32, ch: u32, x: i64, y: i64, color: elmz.Color, cov: u8) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= cw or uy >= ch) return;
    const i = (@as(usize, uy) * cw + ux) * 4;
    const a = @as(f32, @floatFromInt(cov)) / 255.0 * (@as(f32, @floatFromInt(color.a)) / 255.0);
    const inv = 1.0 - a;
    px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * a + @as(f32, @floatFromInt(px[i + 0])) * inv);
    px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * a + @as(f32, @floatFromInt(px[i + 1])) * inv);
    px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * a + @as(f32, @floatFromInt(px[i + 2])) * inv);
}
