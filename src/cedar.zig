//! TrueType text: glyph metrics and rasterisation, via Cedar. Cedar is the font backend
//! inside Elm.

const std = @import("std");
const elmz = @import("elmz");
const gamma = @import("gamma.zig");
const cedar = @import("inkwell");
const ramp = @import("ramp.zig");

/// Bake or fetch the glyph's signed distance field and ramp a stroke band out of
/// it. Cedar owns the field; the band's shape is elm's business, so the ramp is
/// `ramp.strokeCoverageAA` rather than a Cedar function.
fn strokeGlyph(
    cache: *cedar.FieldCache,
    font: *const cedar.Font,
    gid: u16,
    scale: f32,
    phase: cedar.Phase,
    phase_y: cedar.Phase,
    reach: u8,
    width: u8,
    aa: f32,
    out: []u8,
) cedar.GlyphError!cedar.FieldCache.FieldRef {
    const f = try cache.fieldAt(font, gid, scale, phase, phase_y, reach);
    const n = @as(usize, f.w) * @as(usize, f.h);
    if (out.len < n) return error.BufferTooSmall;
    ramp.strokeCoverageAA(f.dist, out[0..n], width, aa);
    return f;
}

/// The BORDER band around a glyph: from the ink boundary outward, leaving the
/// interior to the fill painted after it.
///
/// This is a halo with the feathering removed: same field, same cache, same
/// sign convention, same units. `spread`/`offset` are zero and `falloff` is
/// zero, so only the AA term softens the inner edge and the whole band is
/// solid out to `radius`. Writing a separate ramp for it duplicated the sign
/// and unit reasoning and got both wrong.
fn borderGlyph(
    cache: *cedar.FieldCache,
    font: *const cedar.Font,
    gid: u16,
    scale: f32,
    phase: cedar.Phase,
    phase_y: cedar.Phase,
    reach: u8,
    width: f32,
    aa: f32,
    out: []u8,
) cedar.GlyphError!cedar.FieldCache.FieldRef {
    const f = try cache.fieldAt(font, gid, scale, phase, phase_y, reach);
    const n = @as(usize, f.w) * @as(usize, f.h);
    if (out.len < n) return error.BufferTooSmall;
    ramp.haloCoverageAA(f.dist, out[0..n], f.w, f.h, width + 1.0, -1.0, aa, .glow, 1.0, 0.0, 0.0);
    return f;
}

/// The same for a halo, on whichever side of the contour its mode names.
fn haloGlyph(
    cache: *cedar.FieldCache,
    font: *const cedar.Font,
    gid: u16,
    scale: f32,
    phase: cedar.Phase,
    phase_y: cedar.Phase,
    reach: u8,
    radius: f32,
    falloff: f32,
    aa: f32,
    mode: ramp.HaloMode,
    spread: f32,
    offset: [2]f32,
    out: []u8,
) cedar.GlyphError!cedar.FieldCache.FieldRef {
    const f = try cache.fieldAt(font, gid, scale, phase, phase_y, reach);
    const n = @as(usize, f.w) * @as(usize, f.h);
    if (out.len < n) return error.BufferTooSmall;
    ramp.haloCoverageAA(f.dist, out[0..n], f.w, f.h, radius, falloff, aa, mode, spread, offset[0], offset[1]);
    return f;
}
const linebreak = cedar.linebreak;

// Line breaking is pure Unicode logic with no font data in it, so it lives in
// Inkwell, beside the other tables. Re-exported because callers of this module
// reach for these names here.
pub const BreakClass = linebreak.BreakClass;
/// The RESOLVED class (LB1 applied), which is what wrapping wants: a raw table lookup
/// leaves AI/SA/XX unresolved and every rule keyed on AL then misses.
pub const breakClass = linebreak.resolveClass;
pub const canBreakPair = linebreak.canBreakPair;

/// The resolved `kern` lookup list, which `shape` can be handed instead of rebuilding it
/// per call.
pub const Kern = cedar.Kern;

/// Widest stroke, in DEVICE pixels, that a single baked distance field can
/// answer. Every narrower width re-thresholds the same numbers, so this is the
/// one number that has to be generous rather than exact. Must match
/// `FieldCache.Options.max_width_px`, which is what the bake is sized to.
pub const max_stroke_px: u8 = 12;

pub const V = struct { ascent: f32, descent: f32, line_gap: f32 };

pub const Font = struct {
    /// Bytes of scratch a glyph cache needs at the default options. Published here so a
    /// caller can own the storage without importing Cedar.
    pub const cache_bytes = cedar.Cache.needed(.{});
    /// Size of the glyph distance-field cache, for a caller that sizes its own
    /// storage without importing Cedar. A sibling of `cache_bytes`, not a share
    /// of it: distance fields are four bytes a pixel, coverage one.
    pub const field_bytes = cedar.FieldCache.needed(.{});
    /// Bytes of scratch the codepoint lookup needs, published for the same reason: a caller
    /// sizes its storage without importing Cedar.
    pub const lookup_bytes = cedar.Lookup.needed(.{});
    face: cedar.Font = undefined,
    ok: bool = false,
    /// Cheap identity for caches: which byte buffer this face borrows.
    id: usize = 0,
    /// Which face of a font collection was asked for.
    index: u32 = 0,
    dbg: bool = true,

    cache: cedar.Cache = undefined,
    cache_ok: bool = false,
    /// Distance fields for stroked glyphs. Separate from `cache` on purpose:
    /// one entry serves every stroke width, because a ramp re-thresholds the
    /// same numbers, where coverage would need one per width.
    fields: cedar.FieldCache = undefined,
    fields_ok: bool = false,
    /// Resolved kern lookups, held BY POINTER: `Kern` carries a `Font`, and a `Font`
    /// carrying a `Kern` by value is an infinite type.
    kern: ?*Kern = null,

    lookup: cedar.Lookup = undefined,
    lookup_ok: bool = false,

    pub const none: Font = .{};

    pub fn fingerprint(self: *const Font) usize {
        return if (self.ok) self.id else 0;
    }

    /// The cache key for the CURRENT instance.
    pub fn instanceKey(self: *const Font) usize {
        if (!self.ok) return 0;
        const v: usize = @intCast(self.face.variationId());
        return self.id ^ (@as(usize, self.index) << 3) ^ (v *% 0x9E3779B1);
    }

    /// Whether a real typeface is attached.
    pub fn family(self: *const Font, out: []u8) ?[]const u8 {
        if (!self.ok) return null;
        return self.face.family(out);
    }

    /// Style within the family, e.g. "Bold Oblique".
    pub fn style(self: *const Font, out: []u8) ?[]const u8 {
        if (!self.ok) return null;
        return self.face.style(out);
    }

    pub fn available(self: *const Font) bool {
        return self.ok;
    }

    /// Does this face actually map `cp`?
    pub fn hasGlyph(self: *const Font, cp: u21) bool {
        if (!self.ok) return false;
        // gid 0 is `.notdef`, and `glyphIndex` reports a MISSING character as 0
        // rather than an error -- so "it parsed" is not "it has this glyph". A
        // Noto Thai subset answers 0 for 'H' quite happily.
        const gid = self.face.glyphIndex(cp) catch return false;
        return gid != 0;
    }

    pub fn init(bytes: []const u8) Font {
        return initIndex(bytes, 0);
    }

    /// The Nth face of a font collection (`.ttc`).
    pub fn initIndex(bytes: []const u8, index: u32) Font {
        var f: Font = .{};
        if (bytes.len == 0) return f;
        f.face = cedar.Font.initIndex(bytes, index) catch return f;
        f.ok = true;
        f.id = @intFromPtr(bytes.ptr);
        f.index = index;
        return f;
    }

    /// One axis of the design space, e.g. `wght` from 100 to 900.
    pub const Axis = struct {
        tag: u32,
        min: f32,
        default: f32,
        max: f32,
    };

    /// Pack four ASCII bytes into the tag layout the tables use.
    pub fn tagOf(name: *const [4]u8) u32 {
        return (@as(u32, name[0]) << 24) | (@as(u32, name[1]) << 16) |
            (@as(u32, name[2]) << 8) | @as(u32, name[3]);
    }

    /// How many variation axes the face declares. Zero for a static face, which is the
    /// ordinary case and not a failure.
    pub fn axisCount(self: *const Font) usize {
        if (!self.ok) return 0;
        return self.face.axisCount();
    }

    pub fn axis(self: *const Font, i: usize) ?Axis {
        if (!self.ok) return null;
        const a = self.face.axisInfo(i) orelse return null;
        return .{ .tag = a.tag, .min = a.min, .default = a.default, .max = a.max };
    }

    /// This face pinned to a point in its design space.
    pub fn atCoords(self: *const Font, user: []const f32) Font {
        if (!self.ok) return .{};
        var f = self.*;
        f.face = self.face.withCoords(user);
        f.cache_ok = false;
        f.lookup_ok = false;
        f.kern = null;
        return f;
    }

    /// One layer of a colour glyph: a glyph id and the palette entry it takes its colour
    /// from.
    pub const ColorLayer = struct {
        glyph: u16,
        palette_index: u16,
    };
    /// A resolved colour, straight out of the face's CPAL palette.
    pub const Rgba = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    /// Whether the face carries colour glyphs at all -- what a caller asks before deciding
    /// to check per glyph.
    pub fn hasColor(self: *const Font) bool {
        if (!self.ok) return false;
        return self.face.hasColor();
    }

    /// The layers of a colour glyph, or null for "draw this normally".
    pub fn colorLayers(self: *const Font, gid: u16, out: []ColorLayer) ?[]ColorLayer {
        if (!self.ok) return null;
        // Cedar's `Layer` and this one are the same two u16s in the same order,
        // but they are different types, so the copy is explicit -- a cast would
        // break silently if either side grew a field. Caller storage, so a
        // fixed scratch is the only allocation on this path and there is none.
        const n = @min(out.len, max_layers);
        var scratch: [max_layers]cedar.Layer = undefined;
        const got = self.face.colorLayers(gid, scratch[0..n]) orelse return null;
        for (got, 0..) |l, i| out[i] = .{ .glyph = l.glyph, .palette_index = l.palette_index };
        return out[0..got.len];
    }

    /// Largest layer stack accepted.
    pub const max_layers = 32;

    /// A colour from the face's palette.
    pub fn paletteColor(self: *const Font, palette: u16, index: u16) ?Rgba {
        if (!self.ok) return null;
        const c = self.face.paletteColor(palette, index) orelse return null;
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }

    /// Point the glyph cache at caller-owned storage. Must be called after the `Font` is in
    /// its final home, because the cache keeps slices into `mem`.
    pub const kern_bytes = Kern.needed(.{});

    /// Point this face at a resolved kern cache.
    pub fn attachKern(self: *Font, slot: *Kern, mem: []align(8) u8) void {
        if (!self.ok) return;
        slot.* = Kern.init(mem, self.face, .{});
        // Refuse a cache for other bytes: its lookup indices address another
        // face's tables.
        if (slot.font.data.ptr == self.face.data.ptr) self.kern = slot;
    }

    pub fn attachCache(self: *Font, mem: []align(8) u8) void {
        if (!self.ok) return;
        self.cache = cedar.Cache.init(mem, .{}) catch return;
        self.cache_ok = true;
    }

    pub fn attachFields(self: *Font, mem: []align(8) u8) void {
        if (!self.ok) return;
        // `max_width_px` is the widest stroke ONE baked field can answer:
        // the field is baked to this distance and any narrower width is a
        // threshold change on the same numbers. The default of 4 rejected
        // the theme's `.stroke = 6` outright with `error.FieldTooNarrow`,
        // and `strokeText` has no better answer than a silent fall-back to
        // the fill -- which reads as "stroke does nothing", not as a limit.
        self.fields = cedar.FieldCache.init(mem, .{ .max_width_px = max_stroke_px }) catch return;
        self.fields_ok = true;
    }

    /// Point the codepoint lookup at caller-owned storage.
    pub fn attachLookup(self: *Font, mem: []align(8) u8) void {
        if (!self.ok) return;
        self.lookup = cedar.Lookup.init(mem, .{}) catch return;
        self.lookup_ok = true;
    }

    /// Counters for the codepoint lookup, or null when none is attached.
    pub fn lookupStats(self: *const Font) ?cedar.Lookup.Stats {
        if (!self.lookup_ok) return null;
        return self.lookup.stats;
    }

    /// Resolve a codepoint to its glyph and advance, through the lookup when one is
    /// attached.
    fn glyphFor(self: *const Font, cp: u21) cedar.Lookup.Entry {
        if (self.lookup_ok) {
            const mut = @constCast(self);
            return mut.lookup.resolve(&self.face, cp) catch .{ .gid = 0, .advance = 0 };
        }
        const gid = self.face.glyphIndex(cp) catch 0;
        const hm = self.face.hMetrics(gid) catch cedar.HMetrics{ .advance = 0, .lsb = 0 };
        return .{ .gid = gid, .advance = hm.advance };
    }

    /// Counters for the glyph cache, or null when no storage is attached. This exists so a
    /// test can tell a HIT from a re-rasterisation.
    pub fn cacheStats(self: *const Font) ?cedar.Cache.Stats {
        if (!self.cache_ok) return null;
        return self.cache.stats;
    }

    /// Pixels per font unit. `size` names the EM SQUARE.
    fn scaleFor(self: *const Font, size: f32) f32 {
        const upem = self.face.units_per_em;
        if (upem == 0) return 1;
        return size / @as(f32, @floatFromInt(upem));
    }

    /// The line box for `size`, normalised so `ascent + descent == size`. `size` names the
    /// EM, and the em is what a caller's box is.
    pub fn verticalMetrics(self: *const Font, size: f32) V {
        if (!self.ok) return .{ .ascent = size, .descent = 0, .line_gap = 0 };
        const v = self.face.vMetrics();
        // THE SAME scale the glyphs are rasterised with. Normalising the span
        // to `size` (the old code divided by asc - desc) shrinks the descent
        // to desc/span of the em and lifts the baseline, so a box sized to
        // `size` cannot hold the glyph: Arabic came out asc 19.52 desc -10.48
        // on a face whose real proportion is 0.80/0.20 of a 1.448 em span.
        const s = self.scaleFor(size);
        return .{
            .ascent = @as(f32, @floatFromInt(v.ascender)) * s,
            .descent = @as(f32, @floatFromInt(v.descender)) * s,
            .line_gap = @as(f32, @floatFromInt(v.line_gap)) * s,
        };
    }

    /// A laid-out window of text: glyph ids and their advances, in font units, with pair
    /// kerning already applied. Kerning is Cedar's business.
    const run_max = 128;
    /// Codepoints one `wrap` call can see. A paragraph, not a document.
    pub const wrap_max_cps = 2048;

    const Run = struct {
        gids: [run_max]u16 = undefined,
        advs: [run_max]i32 = undefined,
        len: usize = 0,
    };

    /// True when the run is Arabic script and needs joining forms. The Arabic and Arabic
    /// Supplement blocks plus the presentation forms.
    fn isArabic(cps: []const u21) bool {
        for (cps) |cp| {
            switch (cp) {
                0x0600...0x06FF, // Arabic
                0x0750...0x077F, // Arabic Supplement
                0x08A0...0x08FF, // Arabic Extended-A
                0xFB50...0xFDFF, // Arabic Presentation Forms-A
                0xFE70...0xFEFF, // Arabic Presentation Forms-B
                => return true,
                else => {},
            }
        }
        return false;
    }

    /// Advance for one glyph id, in font units. The fallback when the generic shaper
    /// declines a run, so a glyph still moves the pen.
    fn advanceOfGid(face: *const cedar.Font, gid: u16) i32 {
        if (face.hMetricsResolved(gid)) |m| return @as(i32, m.advance) else |_| {}
        if (face.hMetrics(gid)) |m| return @as(i32, m.advance) else |_| {}
        return 0;
    }

    /// Lay out from `at`, stopping at a newline, the end of the text, or the window.
    /// Returns the byte to resume from.
    fn layoutRun(self: *const Font, bytes: []const u8, at: usize, run: *Run) usize {
        var cps: [run_max]u21 = undefined;
        var i = at;
        var n: usize = 0;
        while (i < bytes.len and n < run_max) {
            const cp = decode(bytes, &i);
            if (cp == '\n') break;
            cps[n] = cpOf(cp);
            n += 1;
        }
        run.len = 0;
        // Arabic runs take a DIFFERENT shaper. The generic `shape` applies
        // ccmp/locl/rlig/liga/clig/calt and nothing else -- it has no notion of
        // joining forms, so every letter comes back in its isolated shape and
        // the run reads as loose letters rather than connected script.
        // `shapeArabic` is where init/medi/fina/isol live.
        //
        // It is a separate entry point rather than a flag because the two do
        // genuinely different work, and picking between them is a property of
        // the TEXT, not of the font.
        if (isArabic(cps[0..n])) {
            // A face that cannot map the run's script still answers: `shapeArabic`
            // falls back to `glyphIndex(cp) catch 0` and returns without error
            // when there is no GSUB, so gid 0 (notdef) or a stray cmap hit comes
            // back and the catch below never fires. That is a TOFU run, not a
            // shaped one -- refused here so the caller draws .notdef boxes in
            // the face it actually named rather than a plausible wrong glyph.
            const mappable = for (cps[0..n]) |cp| {
                if (self.face.glyphIndex(cp)) |_| {} else |_| break false;
            } else true;
            if (!mappable) {
                for (cps[0..n], 0..) |cp, k| run.gids[k] = self.glyphFor(cp).gid;
                return i;
            }
            run.len = self.face.shapeArabic(cps[0..n], run.gids[0..n], null) catch blk: {
                for (cps[0..n], 0..) |cp, k| run.gids[k] = self.glyphFor(cp).gid;
                break :blk n;
            };
            // Advances belong to the JOINED glyphs `shapeArabic` just
            // returned, so they are read straight off those gids. A second
            // `shape` call cannot supply them: substitution-on answers with the
            // BASE forms (1365..1395) where `shapeArabic` returns the
            // contextual ones (5337..5366), and substitution-off lays isolate
            // advances behind joined glyphs -- which is a wide gap after every
            // character, the defect this replaces.
            for (run.gids[0..run.len], 0..) |g, k| run.advs[k] = advanceOfGid(&self.face, g);
            // Cedar returns LOGICAL order on purpose -- "the caller reverses
            // for display, because reversing is a property of the writing
            // direction and not of the shaping". This is that reversal. Both
            // arrays move together: reversing gids alone would pair every
            // glyph with the advance of a different one.
            std.mem.reverse(u16, run.gids[0..run.len]);
            std.mem.reverse(i32, run.advs[0..run.len]);
            return i;
        }
        run.len = self.face.shape(cps[0..n], run.gids[0..n], null, .{
            .advances = run.advs[0..n],
            .substitute = true,
            .kern_cache = self.kern,
        }) catch blk: {
            // A face Cedar will not lay out still draws: fall back to the
            // plain per-glyph answer rather than losing the run.
            for (cps[0..n], 0..) |cp, k| {
                const g = self.glyphFor(cp);
                run.gids[k] = g.gid;
                run.advs[k] = g.advance;
            }
            break :blk n;
        };
        return i;
    }

    pub fn measure(self: *const Font, bytes: []const u8, size: f32) elmz.TextMetrics {
        const v = self.verticalMetrics(size);
        if (!self.ok) return .{ .width = 0, .height = size, .ascent = size, .descent = 0, .line_height = size };
        const s = self.scaleFor(size);
        var w: f32 = 0;
        var run: Run = .{};
        var at: usize = 0;
        while (at < bytes.len) {
            at = self.layoutRun(bytes, at, &run);
            for (run.advs[0..run.len]) |a| w += @as(f32, @floatFromInt(a)) * s;
        }
        // `verticalMetrics` is already normalised to the em, so the box is
        // exactly what it reports and the baseline `drawText` computes from
        // the same numbers lands in the same place.
        return .{
            .width = w,
            .height = v.ascent - v.descent,
            .ascent = v.ascent,
            .descent = v.descent,
            .line_height = v.ascent - v.descent + v.line_gap,
        };
    }

    /// Sum a run's advances, which is how every caller converts font units.
    fn advanceSum(advs: []const i32, s: f32) f32 {
        var w: f32 = 0;
        for (advs) |a| w += @as(f32, @floatFromInt(a)) * s;
        return w;
    }

    /// Codepoints in `bytes[start..end]`, NOT counting a trailing newline: `layoutRun`
    /// consumes one but never produces a glyph for it.
    fn cpsIn(bytes: []const u8, start: usize, end: usize) usize {
        var i = start;
        var n: usize = 0;
        const stop = if (end > start and bytes[end - 1] == '\n') end - 1 else end;
        while (i < stop) : (n += 1) _ = decode(bytes, &i);
        return n;
    }

    /// Where a caret sitting before byte `index` belongs, as a width from the start of
    /// `bytes`. `index` is clamped, and 0 answers 0.
    pub fn advanceTo(self: *const Font, bytes: []const u8, size: f32, index: usize) f32 {
        const target = @min(index, bytes.len);
        if (target == 0 or !self.ok) return 0;
        const s = self.scaleFor(size);
        var w: f32 = 0;
        var run: Run = .{};
        var at: usize = 0;
        while (at < bytes.len) {
            const run_start = at;
            at = self.layoutRun(bytes, at, &run);
            if (target >= at) {
                w += advanceSum(run.advs[0..run.len], s);
                continue;
            }
            // The boundary falls inside this run.
            if (cpsIn(bytes, run_start, at) != run.len) {
                return w + self.measure(bytes[run_start..target], size).width;
            }
            var i = run_start;
            var g: usize = 0;
            while (i < target and g < run.len) {
                _ = decode(bytes, &i);
                w += @as(f32, @floatFromInt(run.advs[g])) * s;
                g += 1;
            }
            return w;
        }
        return w;
    }

    /// One laid-out line: the bytes it covers and where the next one starts.
    pub const Line = struct {
        /// Byte range in the source, excluding the separator.
        start: usize,
        end: usize,
        /// Width in pixels at the size the wrap was given.
        width: f32,
    };

    /// Break `bytes` into lines no wider than `max_width`, by UAX #14.
    ///
    /// Writes at most `out.len` lines and returns how many. Fewer lines than the
    /// text needs means `out` was too small; the caller can tell by whether the
    /// last line ended at `bytes.len`.
    ///
    /// A break is taken at the LAST legal opportunity that fits, not the first
    /// one past the edge, because breaking at the first overflow strands
    /// everything that would have fitted. When no legal opportunity exists in a
    /// line's worth of text -- one long word -- the line is cut at the last byte
    /// that fits, since the alternative is an infinitely wide line.
    ///
    /// Newlines are hard breaks and are consumed, not emitted.
    pub fn wrap(self: *const Font, bytes: []const u8, size: f32, max_width: f32, out: []Line) usize {
        if (!self.ok) {
            if (bytes.len != 0 and out.len != 0) {
                out[0] = .{ .start = 0, .end = bytes.len, .width = self.measure(bytes, size).width };
                return 1;
            }
            return 0;
        }

        // Codepoints for the whole string up front: the break rules are a query
        // over a run, and re-folding per candidate line would be quadratic.
        var cps_buf: [wrap_max_cps]u21 = undefined;
        var byte_at: [wrap_max_cps]usize = undefined; // byte offset of each codepoint
        var n: usize = 0;
        var bi: usize = 0;
        while (bi < bytes.len and n < wrap_max_cps) {
            byte_at[n] = bi;
            // decode answers u32; every value it can produce fits u21, since
            // it rejects overlong and out-of-range sequences.
            cps_buf[n] = @intCast(decode(bytes, &bi));
            n += 1;
        }
        byte_at[n] = bytes.len;
        if (n == 0) return 0;

        var breaker: linebreak.Breaker(wrap_max_cps) = .{};
        var can: [wrap_max_cps]bool = undefined;
        breaker.breakBefore(cps_buf[0..n], can[0..n]);

        // Per-codepoint advance in pixels, so a prefix is a running sum.
        var adv: [wrap_max_cps]f32 = undefined;
        self.advancesPerCodepoint(bytes, cps_buf[0..n], size, adv[0..n]);

        var lines: usize = 0;
        var first: usize = 0; // first codepoint of the current line
        var acc: f32 = 0;
        var last_break: ?usize = null; // best break opportunity so far
        var last_break_w: f32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // A newline ends the line wherever it falls.
            if (cps_buf[i] == '\n') {
                if (lines == out.len) return lines;
                out[lines] = .{ .start = byte_at[first], .end = byte_at[i], .width = acc };
                lines += 1;
                first = i + 1;
                acc = 0;
                last_break = null;
                continue;
            }
            // `can[i]` answers "may a line break before cps[i]", so cps[i] is
            // the FIRST character of the next line. The width of the line that
            // ends here therefore excludes adv[i].
            if (i > first and can[i]) {
                last_break = i;
                last_break_w = acc;
            }
            acc += adv[i];
            if (acc <= max_width or i == first) continue;

            // Overflow. Take the last opportunity that fitted; with none, cut
            // here and accept the overflow.
            const cut = last_break orelse i;
            if (lines == out.len) return lines;
            // Measure the line's own bytes. The running sum cannot be trusted
            // across a break -- it is reset at the cut and the cut character is
            // rescanned -- and a width that disagrees with the bytes it claims
            // is worse than the re-measure.
            out[lines] = .{
                .start = byte_at[first],
                .end = byte_at[cut],
                .width = self.measure(bytes[byte_at[first]..byte_at[cut]], size).width,
            };
            lines += 1;
            first = cut;
            // The break position starts the next line; rescan it from scratch,
            // since its advance belongs to the line that begins there.
            acc = 0;
            last_break = null;
            i = cut - 1;
        }
        if (first < n) {
            if (lines == out.len) return lines;
            // Measured rather than accumulated: `acc` can be off by a rescanned
            // break character, and a wrong width is worse than a re-measure.
            out[lines] = .{
                .start = byte_at[first],
                .end = bytes.len,
                .width = self.measure(bytes[byte_at[first]..], size).width,
            };
            lines += 1;
        }
        return lines;
    }

    /// Per-codepoint advances in pixels, honouring shaping.
    ///
    /// A shaping run can collapse several codepoints into one glyph, so the
    /// per-codepoint figure is the run's total spread evenly over the codepoints
    /// it covers. That is exact for a run's sum, which is what a line width is.
    fn advancesPerCodepoint(self: *const Font, bytes: []const u8, cps: []const u21, size: f32, out: []f32) void {
        _ = cps;
        const s = self.scaleFor(size);
        var run: Run = .{};
        var at: usize = 0;
        var k: usize = 0;
        while (at < bytes.len) {
            const run_start = at;
            at = self.layoutRun(bytes, run_start, &run);
            const nc = cpsIn(bytes, run_start, at);
            if (nc == 0) continue;
            const each = advanceSum(run.advs[0..run.len], s) / @as(f32, @floatFromInt(nc));
            var c: usize = 0;
            while (c < nc and k < out.len) : (c += 1) {
                out[k] = each;
                k += 1;
            }
        }
    }

    /// The byte boundary nearest `x` — what a click at `x` puts the caret before.
    pub fn hitText(self: *const Font, bytes: []const u8, size: f32, x: f32) usize {
        if (bytes.len == 0 or !self.ok or x <= 0) return 0;
        const s = self.scaleFor(size);
        var w: f32 = 0;
        var run: Run = .{};
        var at: usize = 0;
        while (at < bytes.len) {
            const run_start = at;
            at = self.layoutRun(bytes, at, &run);
            const run_w = advanceSum(run.advs[0..run.len], s);
            if (w + run_w < x) {
                w += run_w;
                continue;
            }
            if (cpsIn(bytes, run_start, at) != run.len) {
                // Collapsed cluster: resolve at the nearest codepoint boundary
                // by prefix width. Inside a ligature no boundary is real, so
                // this is only ever asked at an edge.
                var i = run_start;
                while (i < at) {
                    const before = i;
                    _ = decode(bytes, &i);
                    const b = w + self.measure(bytes[run_start..before], size).width;
                    const e = w + self.measure(bytes[run_start..i], size).width;
                    if (x <= (b + e) * 0.5) return before;
                }
                w += run_w;
                continue;
            }
            var i = run_start;
            var g: usize = 0;
            while (i < at and g < run.len) {
                const nb = w + @as(f32, @floatFromInt(run.advs[g])) * s;
                if (x <= (w + nb) * 0.5) return i;
                w = nb;
                _ = decode(bytes, &i);
                g += 1;
            }
        }
        return bytes.len;
    }

    /// Greedy line breaking -- the same loop the stb path ran, because a line count that
    /// disagrees by one moves every border and shadow below it.
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
            var break_end = bytes.len;
            var break_next = bytes.len;
            var last_break_end: usize = 0;
            var last_break_next: usize = 0;
            var have_break = false;
            // Seeded with AL: the pre-merge 7-class enum had an `.other`
            // catch-all, and the merged resolver maps the unknown classes
            // (xx, sg) onto AL, so that is its honest equivalent. Only ever
            // read once `at > start`, so the seed cannot decide a real break.
            var prev_class: BreakClass = .al;

            while (i < bytes.len) {
                const at = i;
                const cp = decode(bytes, &i);
                if (cp == '\n') {
                    break_end = at;
                    break_next = i;
                    break;
                }
                // `decode` yields u32 for a whole-UTF-8 codepoint; the class
                // table is indexed by u21, which holds every assignable one.
                const cls = breakClass(@intCast(cp));
                if (cls == .sp) {
                    last_break_end = at;
                    last_break_next = i;
                    have_break = true;
                } else if (at > start and canBreakPair(prev_class, cls)) {
                    // A break BETWEEN two characters: the next line begins at
                    // this one, so no codepoint is consumed by the break. A
                    // space is the other kind -- it is consumed.
                    last_break_end = at;
                    last_break_next = at;
                    have_break = true;
                }
                prev_class = cls;
                // Unkerned on purpose: this loop's quirks decide a line count,
                // and a line count that disagrees by one moves every border
                // below it. Pair adjustment shifts a line by a rounding error;
                // it does not decide where a line breaks.
                if (self.ok) {
                    w += @as(f32, @floatFromInt(self.glyphFor(cpOf(cp)).advance)) * s;
                } else w += fallback;
                if (w > max_w and at > start) {
                    if (have_break and last_break_next > start) {
                        break_end = last_break_end;
                        break_next = last_break_next;
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

    /// Draw a UTF-8 run.
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
        const solid_c: ?elmz.Color = switch (fill) {
            .solid => |cc| cc,
            else => null,
        };
        // Measuring first costs a SECOND full layout of the same string, and a
        // layout is no longer two table reads: it resolves the feature lists,
        // positions every pair, applies substitution and produces advances.
        // The box exists only to answer `colorAt` below, which `orelse` never
        // reaches for a solid fill -- so nearly every label in a UI was paying
        // twice to compute a width nobody read. Gradient text still measures,
        // because there the colour of a glyph depends on where it sits.
        var box: elmz.Rect = .{ .x = x, .y = y, .w = 0, .h = 0 };
        if (solid_c == null) {
            const tm = self.measure(bytes, size);
            box = .{ .x = x, .y = y, .w = tm.width, .h = tm.height };
        }
        // Clip is the RUN's rect, not the canvas: a glow grows well past the
        // glyph bounds, so clamping to the run truncated it to a rectangle the
        // size of the text. Intersect with the target instead and let the
        // element rect do its job only where it is narrower than the canvas.
        const cx0: i64 = @max(0, @as(i64, @intFromFloat(@floor(clip.x))));
        const cy0: i64 = @max(0, @as(i64, @intFromFloat(@floor(clip.y))));
        const cx1: i64 = @min(@as(i64, cw), @as(i64, @intFromFloat(@ceil(clip.x + clip.w))));
        const cy1: i64 = @min(@as(i64, ch), @as(i64, @intFromFloat(@ceil(clip.y + clip.h))));
        const s = self.scaleFor(size);
        const baseline = y + self.verticalMetrics(size).ascent;
        const mut = @constCast(self);
        var pen = x;
        var at: usize = 0;
        var run: Run = .{};
        while (at < bytes.len) {
            at = self.layoutRun(bytes, at, &run);
            for (run.gids[0..run.len], run.advs[0..run.len]) |gid, adv| {
                const r = mut.cache.maskAt(&self.face, gid, s, .zero) catch null;

                if (r) |rr| {
                    if (rr.w > 0 and rr.h > 0) {
                        // `x0`/`y0` are PIXELS ALREADY: `bitmapBoxPhase` floors
                        // and ceils them after multiplying by `scale`, so a
                        // second multiply by `s` shrank a -25px offset to -0.4
                        // and dropped every Latin and CJK glyph half a line
                        // below its baseline, straight through the clip.
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

                pen += @as(f32, @floatFromInt(adv)) * s;
            }
        }
    }

    /// The same string `drawText` lays out, drawn as an OUTLINE `width` pixels
    /// wide instead of a fill: the interior is left alone.
    ///
    /// Deliberately a sibling of `drawText` and not a flag inside it. The two
    /// walk the identical pen/run loop -- same layout, same advances, same
    /// phase-zero grid the coverage cache uses -- but they composite different
    /// things: coverage of the glyph versus a ramp over a distance field. A
    /// flag would have put a four-byte-per-pixel field on the path every plain
    /// label takes.
    ///
    /// Returns false when the face cannot answer, so the caller can fall back
    /// to the fill rather than draw nothing.
    pub fn strokeText(
        self: *const Font,
        px: []u8,
        cw: u32,
        ch: u32,
        x: f32,
        y: f32,
        size: f32,
        fill: elmz.Fill,
        bytes: []const u8,
        width: u8,
        clip: elmz.Rect,
        scratch: []u8,
    ) bool {
        return self.bandedText(px, cw, ch, x, y, size, fill, bytes, width, .stroke, clip, scratch);
    }

    /// Glyph text drawn as a BAND around each outline rather than a solid fill.
    /// `Banded.kind` picks which band: a `.stroke` replaces the fill and leaves
    /// the interior hollow, while a `.border` runs from the ink boundary
    /// outward so a fill can be painted inside it afterwards. Everything else --
    /// layout, pen advance, field cache, blending -- is shared, which is why
    /// there is one body and not two.
    pub const Banded = enum { stroke, border };

    pub fn borderedText(
        self: *const Font,
        px: []u8,
        cw: u32,
        ch: u32,
        x: f32,
        y: f32,
        size: f32,
        fill: elmz.Fill,
        bytes: []const u8,
        width: u8,
        clip: elmz.Rect,
        scratch: []u8,
    ) bool {
        return self.bandedText(px, cw, ch, x, y, size, fill, bytes, width, .border, clip, scratch);
    }

    fn bandedText(
        self: *const Font,
        px: []u8,
        cw: u32,
        ch: u32,
        x: f32,
        y: f32,
        size: f32,
        fill: elmz.Fill,
        bytes: []const u8,
        width: u8,
        kind: Banded,
        clip: elmz.Rect,
        scratch: []u8,
    ) bool {
        if (!self.ok or !self.fields_ok) {
            return false;
        }
        const solid_c: ?elmz.Color = switch (fill) {
            .solid => |cc| cc,
            else => null,
        };
        var box: elmz.Rect = .{ .x = x, .y = y, .w = 0, .h = 0 };
        if (solid_c == null) {
            const tm = self.measure(bytes, size);
            box = .{ .x = x, .y = y, .w = tm.width, .h = tm.height };
        }
        // Clip is the RUN's rect, not the canvas: a glow grows well past the
        // glyph bounds, so clamping to the run truncated it to a rectangle the
        // size of the text. Intersect with the target instead and let the
        // element rect do its job only where it is narrower than the canvas.
        const cx0: i64 = @max(0, @as(i64, @intFromFloat(@floor(clip.x))));
        const cy0: i64 = @max(0, @as(i64, @intFromFloat(@floor(clip.y))));
        const cx1: i64 = @min(@as(i64, cw), @as(i64, @intFromFloat(@ceil(clip.x + clip.w))));
        const cy1: i64 = @min(@as(i64, ch), @as(i64, @intFromFloat(@ceil(clip.y + clip.h))));
        const s = self.scaleFor(size);
        const baseline = y + self.verticalMetrics(size).ascent;
        const mut = @constCast(self);
        var pen = x;
        var at: usize = 0;
        var run: Run = .{};
        var drew = false;
        while (at < bytes.len) {
            at = self.layoutRun(bytes, at, &run);
            for (run.gids[0..run.len], run.advs[0..run.len]) |gid, adv| {
                // `.zero`, and it has to be the SAME phase the fill uses: the
                // mask cache above is queried at `.zero`, so a field baked on
                // any other grid would sit a subpixel off its own fill, which
                // at a 1px width is the entire stroke.
                // `aa` is the TOTAL ramp width in pixels, centred on each band
                // boundary -- half a pixel of transition each side at 1.0.
                // It scales with the stroke: a wide band's boundary cuts
                // across pixels at a shallower angle than a thin one's, so a
                // fixed 1px transition reads as stairs on a 6px stroke while
                // looking smooth on a 1px one. Capped so the ramp never eats
                // more than a quarter of the band.
                const aa_w = @min(@as(f32, @floatFromInt(width)) * 0.5, 2.0);
                const aa_dev = @max(aa_w, 1.0);
                // Border band starts AT the ink boundary, so its width is the
                // device width measured outward; a stroke straddles it. Both
                // draw from the reach that width implies.
                const r = switch (kind) {
                    .stroke => strokeGlyph(&mut.fields, &self.face, gid, s, .zero, .zero, width, width, aa_dev, scratch) catch null,
                    .border => borderGlyph(&mut.fields, &self.face, gid, s, .zero, .zero, if (width < 12) width + 1 else width, @floatFromInt(width), aa_dev, scratch) catch null,
                };
                if (r) |rr| {
                    if (rr.w > 0 and rr.h > 0) {
                        // `x0`/`y0` are already pixels, for the same reason the
                        // mask path's are: `bitmapBoxPhase` floors and ceils
                        // after multiplying by `scale`.
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
                                const cov = scratch[row * rr.w + col];
                                if (cov == 0) continue;
                                drew = true;
                                blend(px, cw, ch, gx_px, py, solid_c orelse fill.colorAt(
                                    box,
                                    @as(f32, @floatFromInt(gx_px)) + 0.5,
                                    @as(f32, @floatFromInt(py)) + 0.5,
                                ), cov);
                            }
                        }
                    }
                }
                pen += @as(f32, @floatFromInt(adv)) * s;
            }
        }
        return drew;
    }

    /// Draw a HALO around the glyphs: a band OUTSIDE the contour, behind the
    /// letterform, faded toward `radius`.
    ///
    /// Same machinery as `strokeText` and the same cached distance field, with
    /// the inner half of the band discarded -- ink is negative and outside is
    /// positive, so keeping `d > 0` is the whole of "behind the glyph". That is
    /// why a glow needs no stencil pass to avoid painting over its own letters.
    ///
    /// Returns false when the face cannot answer, so the caller can fall back to
    /// drawing nothing rather than a wrong shape.
    pub fn haloText(
        self: *const Font,
        px: []u8,
        cw: u32,
        ch: u32,
        x: f32,
        y: f32,
        size: f32,
        color: elmz.Color,
        bytes: []const u8,
        radius: f32,
        falloff: f32,
        mode: ramp.HaloMode,
        spread: f32,
        offset: [2]f32,
        clip: elmz.Rect,
        scratch: []u8,
    ) bool {
        if (!self.ok or !self.fields_ok) return false;
        if (color.a == 0 or radius <= 0) return false;
        // Clip is the RUN's rect, not the canvas: a glow grows well past the
        // glyph bounds, so clamping to the run truncated it to a rectangle the
        // size of the text. Intersect with the target instead and let the
        // element rect do its job only where it is narrower than the canvas.
        const cx0: i64 = @max(0, @as(i64, @intFromFloat(@floor(clip.x))));
        const cy0: i64 = @max(0, @as(i64, @intFromFloat(@floor(clip.y))));
        const cx1: i64 = @min(@as(i64, cw), @as(i64, @intFromFloat(@ceil(clip.x + clip.w))));
        const cy1: i64 = @min(@as(i64, ch), @as(i64, @intFromFloat(@ceil(clip.y + clip.h))));
        const s = self.scaleFor(size);
        const baseline = y + self.verticalMetrics(size).ascent;
        const mut = @constCast(self);
        // Baked to the FULL reach: a field baked exactly to `radius` has no
        // samples beyond it, so the fade would be cut off at the rim. `spread`
        // pushes the band further out, and `offset` slides it, so both widen
        // what has to be baked or the glow is clipped on one side.
        const band: f32 = radius + @max(0.0, spread) + @max(@abs(offset[0]), @abs(offset[1]));
        const reach_f: f32 = @ceil(band) + 1.0;
        const reach: u8 = @intFromFloat(@min(reach_f, @as(f32, @floatFromInt(cedar.max_stroke_px))));
        const aa_w: f32 = @min(radius * 0.5, 2.0);
        var pen = x;
        var at: usize = 0;
        var run: Run = .{};
        var drew = false;
        while (at < bytes.len) {
            at = self.layoutRun(bytes, at, &run);
            for (run.gids[0..run.len], run.advs[0..run.len]) |gid, adv| {
                const r = haloGlyph(&mut.fields, &self.face, gid, s, .zero, .zero, reach, radius, falloff, @max(aa_w, 1.0), mode, spread, offset, scratch) catch null;
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
                                const cov = scratch[row * rr.w + col];
                                if (cov == 0) continue;
                                drew = true;
                                blend(px, cw, ch, gx_px, py, color, cov);
                            }
                        }
                    }
                }
                pen += @as(f32, @floatFromInt(adv)) * s;
            }
        }
        return drew;
    }
};

fn cpOf(cp: u32) u21 {
    return if (cp <= 0x10FFFF) @intCast(cp) else 0xFFFD;
}

/// One codepoint from UTF-8. Malformed input yields U+FFFD and consumes one byte, so a bad
/// string degrades to boxes instead of a crash or a loop.
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

/// Blend one glyph pixel.
fn blend(px: []u8, cw: u32, ch: u32, x: i64, y: i64, color: elmz.Color, cov: u8) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= cw or uy >= ch) return;
    const i = (@as(usize, uy) * cw + ux) * 4;
    const a = @as(f32, @floatFromInt(cov)) / 255.0 * (@as(f32, @floatFromInt(color.a)) / 255.0);
    // In light, not in bytes: a glyph edge is exactly the fractional coverage
    // where interpolating encoded channels loses the most.
    px[i + 0] = gamma.blend(px[i + 0], color.r, a);
    px[i + 1] = gamma.blend(px[i + 1], color.g, a);
    px[i + 2] = gamma.blend(px[i + 2], color.b, a);
    // Skipped when the destination is already opaque, which is every glyph in
    // a normally-painted frame -- so this costs one byte compare per pixel.
    if (px[i + 3] != 255) {
        const da = @as(f32, @floatFromInt(px[i + 3])) / 255.0;
        const out = a + da * (1.0 - a);
        px[i + 3] = @intFromFloat(@round(out * 255.0));
    }
}

// ---------------------------------------------------------------------------
// Tests.
//
// This file had none until the face-index/axes/colour surface landed, which
// meant a change here was verified only by "the examples still compile" --
// the green-where-it-never-ran class. They are declared here rather than in
// software.zig because that is where the behaviour lives; build.zig points a
// test root at this file so they actually execute.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The one face the tests use, and where to get it. Deliberately NOT a search across
/// whatever the machine happens to have.
const fixture_face = "/usr/share/fonts/dejavu/DejaVuSans.ttf";

/// A SECOND face, used where the test needs a real font and the box has no DejaVu.
const fixture_face_alt = "/root/NovusGroteskVF-cff2.otf.ttf";

fn anyFace(bytes_out: []u8) ?[]const u8 {
    // readFile returns the filled slice itself; slicing it again is a type
    // error (usize expected) and was a real one until this fix.
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_][]const u8{ fixture_face, fixture_face_alt }) |path| {
        if (std.Io.Dir.cwd().readFile(io, path, bytes_out)) |b| return b else |_| {}
    }
    return null;
}

test "two faces of one collection do not share a cache key" {
    // The bug this guards: the cache key was the byte pointer alone, so two
    // faces of a `.ttc` differed by nothing and a cache served one's glyphs
    // for the other's -- silently, forever. Built from real faces because the
    // property is about what `instanceKey` is computed FROM, and fabricating a
    // `Font` would let the field drop out and still pass.
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;

    var a = Font.initIndex(bytes, 0);
    try testing.expect(a.available());
    var b = a;
    b.index = 1; // same bytes, different face of the collection

    // Both borrow the SAME buffer, so `fingerprint` cannot tell them apart --
    // that is the whole point of the change.
    try testing.expectEqual(a.fingerprint(), b.fingerprint());
    // `instanceKey` must.
    try testing.expect(a.instanceKey() != b.instanceKey());
}

test "a face with no storage answers no axes and no colour" {
    const f = Font.none;
    try testing.expectEqual(@as(usize, 0), f.axisCount());
    try testing.expect(f.axis(0) == null);
    try testing.expect(!f.hasColor());
    try testing.expect(f.paletteColor(0, 0) == null);
    var layers: [4]Font.ColorLayer = undefined;
    try testing.expect(f.colorLayers(1, &layers) == null);
    try testing.expectEqual(@as(usize, 0), f.instanceKey());
}

test "initIndex on a non-collection reads face zero rather than refusing" {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    const zero = Font.initIndex(bytes, 0);
    try testing.expect(zero.available());
    // A plain .ttf has one face; asking for face 7 must not hand back a valid
    // face, and must not crash trying.
    const seventh = Font.initIndex(bytes, 7);
    try testing.expect(!seventh.available());
}

test "a static face reports no axes and atCoords returns it unchanged" {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    const f = Font.init(bytes);
    try testing.expect(f.available());
    // DejaVuSans and Roboto-Regular are both static; if this machine's first
    // font happens to be variable the test is meaningless, so say so rather
    // than assert a fact that is not about the code.
    if (f.axisCount() != 0) return error.SkipZigTest;
    const pinned = f.atCoords(&.{700});
    try testing.expect(pinned.available());
    try testing.expectEqual(f.instanceKey(), pinned.instanceKey());
    try testing.expectEqual(f.index, pinned.index);
}

test "atCoords drops the attached caches instead of sharing them" {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    var f = Font.init(bytes);
    try testing.expect(f.available());
    f.cache_ok = true;
    f.lookup_ok = true;
    const pinned = f.atCoords(&.{});
    // The caches hold slices into caller storage. Carrying `cache_ok` across
    // would give one buffer two owners, which is how it gets truncated under
    // whichever instance draws second.
    try testing.expect(!pinned.cache_ok);
    try testing.expect(!pinned.lookup_ok);
    try testing.expect(pinned.kern == null);
}

test "a monochrome face has no colour, and asking costs no error" {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    const f = Font.init(bytes);
    try testing.expect(f.available());
    // Every desktop font is monochrome; an emoji face is not, so a machine that
    // has one installed would make this assertion wrong about the FACE while
    // the code under test is still correct.
    if (f.hasColor()) return error.SkipZigTest;
    var layers: [4]Font.ColorLayer = undefined;
    try testing.expect(f.colorLayers(1, &layers) == null);
    try testing.expect(f.paletteColor(0, 0) == null);
}

test "colour layers truncate at the cap rather than overrunning caller storage" {
    // The cap is what keeps this allocation-free. A caller passing more storage
    // than max_layers must not make the scratch array index past its end.
    var out: [Font.max_layers + 8]Font.ColorLayer = undefined;
    const f = Font.none;
    try testing.expect(f.colorLayers(0, &out) == null);
    // And a caller passing fewer than the cap is equally null on a dead face --
    // the point is that neither slice length panics.
    var small: [2]Font.ColorLayer = undefined;
    try testing.expect(f.colorLayers(0, &small) == null);
}

test "axis tags pack the way the tables spell them" {
    // "wght" is 0x77676874 in the format. A byte-order slip here names an axis
    // nothing answers to, silently.
    try testing.expectEqual(@as(u32, 0x77676874), Font.tagOf("wght"));
    try testing.expectEqual(@as(u32, 0x77647468), Font.tagOf("wdth"));
}

test "wrap breaks at legal opportunities and never exceeds the width" {
    // Real advances, because the whole question is arithmetic over them: a
    // fabricated advance table would let the scale factor drop out and still
    // pass, which is how an overflow check becomes decorative.
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    const f = Font.init(bytes);
    if (!f.ok) return error.SkipZigTest;

    const text = "the quick brown fox jumps over the lazy dog";
    const size: f32 = 16;
    const max: f32 = 90;

    var lines: [64]Font.Line = undefined;
    const n = f.wrap(text, size, max, &lines);
    try testing.expect(n > 1); // it must actually wrap
    try testing.expect(lines[n - 1].end == text.len); // nothing dropped

    var at: usize = 0;
    for (lines[0..n]) |ln| {
        try testing.expect(ln.start == at); // contiguous, no gaps
        try testing.expect(ln.end > ln.start); // no empty line
        // The width reported is the width of the bytes it claims.
        const w = f.measure(text[ln.start..ln.end], size).width;
        try testing.expect(@abs(w - ln.width) < 0.5);
        // No line may be wider than the box, except a single unbreakable word.
        try testing.expect(w <= max + 0.5 or ln.end == text.len);
        at = ln.end;
    }
    try testing.expect(at == text.len);
}

test "wrap prefers the last opportunity that fits, not the first past the edge" {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    const f = Font.init(bytes);
    if (!f.ok) return error.SkipZigTest;

    const text = "aa bb cc dd ee ff gg";
    var lines: [64]Font.Line = undefined;
    const n = f.wrap(text, 16, 60, &lines);
    try testing.expect(n > 1);

    // Every break must fall at a space, never mid-word: the words here are
    // short enough that a correct walk always finds one.
    for (lines[0 .. n - 1]) |ln| {
        try testing.expect(text[ln.end - 1] == ' ' or text[ln.end] == ' ');
        try testing.expect(!(ln.end > 0 and text[ln.end - 1] != ' ' and text[ln.end] != ' '));
    }
    // And no line should be a lone fragment when a fuller one would fit.
    for (lines[0..n]) |ln| {
        try testing.expect(ln.width <= 60 + 0.5);
    }
}

test "wrap honours a hard newline and drops the separator" {
    var buf: [16 * 1024 * 1024]u8 = undefined;
    const bytes = anyFace(&buf) orelse return error.SkipZigTest;
    const f = Font.init(bytes);
    if (!f.ok) return error.SkipZigTest;

    const text = "aa\nbb";
    var lines: [8]Font.Line = undefined;
    const n = f.wrap(text, 16, 1000, &lines);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("aa", text[lines[0].start..lines[0].end]);
    try testing.expectEqualStrings("bb", text[lines[1].start..lines[1].end]);
}
