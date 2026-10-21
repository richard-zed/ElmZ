//! TrueType text: glyph metrics and rasterisation, via Cedar.
//!
//! Cedar is the font backend inside Elm. It is a separate project, published as
//! `glyfz`; that name appears once below, in the import, and nowhere else.
//!
//! No C and no stb. Cedar parses the face and rasterises the outline, and the
//! glyph cache behind `drawText` is the reason the switch pays: stb allocates,
//! rasterises and frees once per glyph per draw, where a cache hit here is a
//! hash lookup and a slice into memory the caller already owns.
//!
//! There is no embedded font. A `Font` is made from bytes the caller owns and
//! borrows them for as long as it is used. Every metric and every glyph comes
//! from that same face, which is why layout and paint agree -- the bug class
//! this module exists to avoid.
//!
//! THE SIZE CONVENTION IS stb's, not the obvious one: text scales by
//! `size / (ascender - descender)`, NOT `size / units_per_em`. Elm has always
//! been sized the first way, and Cedar is driven the first way here; the two
//! differ by ~16% on a real face, so getting it wrong moves every glyph.
//!
//! The cache needs storage and Cedar allocates nothing, so the caller supplies
//! it through `attachCache`. It is deliberately NOT a field of `Font`: the
//! cache holds slices into that storage, and a `Font` carrying its own arena
//! would leave those slices pointing into a temporary the moment the value is
//! returned or copied.

const std = @import("std");
const elmz = @import("elmz");
const cedar = @import("glyfz");

pub const V = struct { ascent: f32, descent: f32, line_gap: f32 };

pub const Font = struct {
    /// Bytes of scratch a glyph cache needs at the default options. Published
    /// here so a caller can own the storage without importing Cedar.
    pub const cache_bytes = cedar.Cache.needed(.{});
    face: cedar.Font = undefined,
    ok: bool = false,
    /// Cheap identity for caches: which byte buffer this face borrows.
    id: usize = 0,

    cache: cedar.Cache = undefined,
    cache_ok: bool = false,

    pub const none: Font = .{};

    pub fn fingerprint(self: *const Font) usize {
        return if (self.ok) self.id else 0;
    }

    pub fn init(bytes: []const u8) Font {
        var f: Font = .{};
        if (bytes.len == 0) return f;
        f.face = cedar.Font.init(bytes) catch return f;
        f.ok = true;
        f.id = @intFromPtr(bytes.ptr);
        return f;
    }

    /// Point the glyph cache at caller-owned storage. Must be called after the
    /// `Font` is in its final home, because the cache keeps slices into `mem`.
    /// A font with no cache still measures; it just paints nothing.
    pub fn attachCache(self: *Font, mem: []align(8) u8) void {
        if (!self.ok) return;
        self.cache = cedar.Cache.init(mem, .{}) catch return;
        self.cache_ok = true;
    }

    /// Counters for the glyph cache, or null when no storage is attached.
    ///
    /// This exists so a test can tell a HIT from a re-rasterisation. A picture
    /// that looks right says nothing about which path produced it -- both
    /// paths draw the same glyph -- so the counters are the only evidence that
    /// the cache is doing anything at all.
    pub fn cacheStats(self: *const Font) ?cedar.Cache.Stats {
        if (!self.cache_ok) return null;
        return self.cache.stats;
    }

    /// stb's ScaleForPixelHeight, reproduced from the same hhea numbers.
    fn scaleFor(self: *const Font, size: f32) f32 {
        const v = self.face.vMetrics();
        const em = @as(f32, @floatFromInt(v.ascender)) - @as(f32, @floatFromInt(v.descender));
        if (em <= 0) return 1;
        return size / em;
    }

    pub fn verticalMetrics(self: *const Font, size: f32) V {
        if (!self.ok) return .{ .ascent = size, .descent = 0, .line_gap = 0 };
        const s = self.scaleFor(size);
        const v = self.face.vMetrics();
        return .{
            .ascent = @as(f32, @floatFromInt(v.ascender)) * s,
            .descent = @as(f32, @floatFromInt(v.descender)) * s,
            .line_gap = @as(f32, @floatFromInt(v.line_gap)) * s,
        };
    }

    fn advanceOf(self: *const Font, s: f32, prev: *u16, cp: u21) f32 {
        const gid = self.face.glyphIndex(cp) catch 0;
        var w: f32 = 0;
        // The legacy `kern` table only -- the same table stb reads. Both
        // therefore return 0 for faces that keep kerning in GPOS.
        if (prev.* != 0) w += @as(f32, @floatFromInt(self.face.kern(prev.*, gid))) * s;
        const hm = self.face.hMetrics(gid) catch cedar.HMetrics{ .advance = 0, .lsb = 0 };
        prev.* = gid;
        return w + @as(f32, @floatFromInt(hm.advance)) * s;
    }

    pub fn measure(self: *const Font, bytes: []const u8, size: f32) elmz.TextMetrics {
        const v = self.verticalMetrics(size);
        if (!self.ok) return .{ .width = 0, .height = size, .ascent = size, .descent = 0, .line_height = size };
        const s = self.scaleFor(size);
        var w: f32 = 0;
        var prev: u16 = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = decode(bytes, &i);
            if (cp == '\n') continue; // a newline is not ink
            w += self.advanceOf(s, &prev, cpOf(cp));
        }
        return .{
            .width = w,
            .height = v.ascent - v.descent,
            .ascent = v.ascent,
            .descent = v.descent,
            .line_height = v.ascent - v.descent + v.line_gap,
        };
    }

    /// Greedy line breaking -- the same loop the stb path ran, because a line
    /// count that disagrees by one moves every border and shadow below it. The
    /// quirks are deliberate: the advance is added BEFORE the overflow test,
    /// and a no-space break resumes past the character that overflowed.
    pub fn wrapLines(self: *const Font, bytes: []const u8, size: f32, max_w: f32, out: [][]const u8) usize {
        if (out.len == 0) return 0;
        const s = if (self.ok) self.scaleFor(size) else 1.0;
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
            var prev: u16 = 0;
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
                if (self.ok) {
                    w += self.advanceOf(s, &prev, cpOf(cp));
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

    /// Draw a UTF-8 run. A kern pair is applied exactly once per gap, to place
    /// the glyph, which is what `advanceOf` does -- so a drawn run is as wide
    /// as its measure. The stb path this replaced applied the pair twice, once
    /// here and again in the advance to the next glyph; that drifted steadily
    /// wider and read as individual letters landing a pixel late.
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
        if (!self.ok or !self.cache_ok) return;
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
        const s = self.scaleFor(size);
        const baseline = y + self.verticalMetrics(size).ascent;
        const mut = @constCast(self);
        var pen = x;
        var prev: u16 = 0;
        var idx: usize = 0;
        while (idx < bytes.len) {
            const cp = decode(bytes, &idx);
            if (cp == '\n') continue;
            const gid = self.face.glyphIndex(cpOf(cp)) catch 0;
            if (prev != 0) pen += @as(f32, @floatFromInt(self.face.kern(prev, gid))) * s;

            const r = mut.cache.maskAt(self.face, gid, s, .zero) catch null;

            if (r) |rr| {
                if (rr.w > 0 and rr.h > 0) {
                    const ox: i64 = @intFromFloat(@round(pen + @as(f32, @floatFromInt(rr.x0))));
                    const oy: i64 = @intFromFloat(@round(baseline + @as(f32, @floatFromInt(rr.y0))));
                    var row: u32 = 0;
                    while (row < rr.h) : (row += 1) {
                        const py = oy + row;
                        if (py < cy0 or py >= cy1) continue;
                        var col: u32 = 0;
                        while (col < rr.w) : (col += 1) {
                            const gx_px = ox + @as(i64, col);
                            if (gx_px < cx0 or gx_px >= cx1) continue;
                            const cov = rr.pixels[row * rr.w + col];
                            if (cov == 0) continue;
                            blend(px, cw, ch, gx_px, py, solid_c orelse fill.colorAt(
                                box,
                                @as(f32, @floatFromInt(gx_px)) + 0.5,
                                @as(f32, @floatFromInt(py)) + 0.5,
                            ), cov);
                        }
                    }
                }
            }

            const hm = self.face.hMetrics(gid) catch cedar.HMetrics{ .advance = 0, .lsb = 0 };
            pen += @as(f32, @floatFromInt(hm.advance)) * s;
            prev = gid;
        }
    }
};

fn cpOf(cp: u32) u21 {
    return if (cp <= 0x10FFFF) @intCast(cp) else 0xFFFD;
}

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
        cp = (cp << 6) | (cont & 0x3F);
    }
    i.* += len;
    return cp;
}

/// Blend one glyph pixel. Coverage is scaled by the colour's own alpha and the
/// destination alpha is left alone -- both matter, and getting either wrong
/// shows up hardest on muted text.
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
