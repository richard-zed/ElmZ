//! The built-in bitmap face: five pixels wide, six tall, one bit per row.
//!
//! Why a library that ships no typeface ships one anyway. Every diagnostic the
//! runtime can raise is TEXT -- an allocation that failed, a duplicate key, a
//! theme file that will not parse, a font path that does not exist. The band
//! that reports them needs a face, so a missing font used to turn "your font
//! is missing" into a blank window: the report of the bug was indistinguishable
//! from the bug. This face is the one that is always present.
//!
//! It is a DIAGNOSTIC CHANNEL, not a fallback typeface. `software.Canvas`
//! reaches for it only when no real face is attached, where the alternative is
//! no text at all. It is legible and it is obviously not the typeface the app
//! asked for, which is exactly the signal wanted: words you can read, and a
//! band above them saying why they look like that. Substituting a *plausible*
//! face would be the one behaviour that could pass for working.
//!
//! The glyphs were drawn by hand and decoded from a single-row sheet, so this
//! is the whole charset there is: a-z, digits, and the punctuation an error
//! message actually uses. Uppercase is folded, because a message that says
//! "Font" in lowercase still reads. Anything else is a `?` -- a wrong glyph is
//! honest about being wrong; a missing one silently shifts everything after it.
//!
//! Multiple-of-six integer sizes only. A bitmap scaled by 1.37 looks like a
//! bitmap scaled by 1.37, so `scaleFor` rounds to whole multiples and the
//! glyphs stay square.

const std = @import("std");
const elmz = @import("elmz");
const cedar = @import("cedar.zig");

/// Cell size in pixels, and the advance that includes the one-column gap.
pub const glyph_w: u32 = 5;
/// The ink box: what `scaleFor` divides a point size by, so the glyph size a
/// caller sees does not move when the line box does.
pub const glyph_h: u32 = 6;
/// The LINE box: the ink box plus room for the glyphs that hang below the
/// baseline. Eight rows is the ink box plus two, which is exactly the deepest
/// drop in `dyOf` (`j p q`), so the lowest pixel of the tallest descender lands
/// on the last row of the box rather than being clipped by it. It is separate
/// from `glyph_h` on purpose: a descender needs somewhere to go, and a taller
/// ink box would silently repoint every size at smaller glyphs.
///
/// This is the number to raise if a deeper drop is ever wanted -- nine rows
/// buys three. Lower it and the descenders are drawn outside the element box and
/// clipped away, which looks exactly like a glyph nobody moved.
pub const line_h: u32 = 8;
pub const advance: u32 = glyph_w + 1;

/// Every glyph this face can spell, in table order. Kept as a string so a test
/// can walk it and so the order is visible without counting array indices.
pub const order = "abcdefghijklmnopqrstuvwxyz1234567890.!,'\":[]/~+?-=_ ";

/// One byte per row, low five bits, bit 4 = leftmost pixel.
pub const glyphs = [_][glyph_h]u8{
    .{ 0b00000, 0b01100, 0b00010, 0b01110, 0b10010, 0b11101 }, // a
    .{ 0b01000, 0b01000, 0b01010, 0b01101, 0b01001, 0b10110 }, // b
    .{ 0b00000, 0b00000, 0b00110, 0b01000, 0b01000, 0b00110 }, // c
    .{ 0b00010, 0b00010, 0b01010, 0b10110, 0b10010, 0b01101 }, // d
    .{ 0b00000, 0b01100, 0b10010, 0b11100, 0b10000, 0b01100 }, // e
    .{ 0b00010, 0b00100, 0b00100, 0b00110, 0b00100, 0b01000 }, // f
    .{ 0b00000, 0b00110, 0b01001, 0b00111, 0b00001, 0b00110 }, // g
    .{ 0b10000, 0b01000, 0b01010, 0b01101, 0b01001, 0b01001 }, // h
    .{ 0b00000, 0b00010, 0b00000, 0b00100, 0b00100, 0b00100 }, // i
    .{ 0b00010, 0b00000, 0b00010, 0b00010, 0b00010, 0b01100 }, // j
    .{ 0b01000, 0b01000, 0b01010, 0b01100, 0b01010, 0b10010 }, // k
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01100 }, // l
    .{ 0b00000, 0b00000, 0b00000, 0b11010, 0b10101, 0b10101 }, // m
    .{ 0b00000, 0b00000, 0b00000, 0b01100, 0b01010, 0b01010 }, // n
    .{ 0b00000, 0b00000, 0b00110, 0b01001, 0b01001, 0b00110 }, // o
    .{ 0b01100, 0b01010, 0b01110, 0b01000, 0b01000, 0b10000 }, // p
    .{ 0b00110, 0b01010, 0b01110, 0b00010, 0b00010, 0b00001 }, // q
    .{ 0b00000, 0b00000, 0b10110, 0b01000, 0b01000, 0b01000 }, // r
    .{ 0b00000, 0b01100, 0b10000, 0b01100, 0b00010, 0b01100 }, // s
    .{ 0b01000, 0b00100, 0b00100, 0b01110, 0b00100, 0b00100 }, // t
    .{ 0b00000, 0b00000, 0b00000, 0b01010, 0b01010, 0b01101 }, // u
    .{ 0b00000, 0b00000, 0b00000, 0b10010, 0b01010, 0b00100 }, // v
    .{ 0b00000, 0b00000, 0b00000, 0b10101, 0b10101, 0b01010 }, // w
    .{ 0b00000, 0b00000, 0b00000, 0b01010, 0b00100, 0b01010 }, // x
    .{ 0b00000, 0b00000, 0b01010, 0b00110, 0b00010, 0b00100 }, // y
    .{ 0b00000, 0b00000, 0b11110, 0b00100, 0b01000, 0b11110 }, // z
    .{ 0b01000, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, // 1
    .{ 0b00110, 0b01001, 0b00010, 0b00100, 0b01000, 0b01111 }, // 2
    .{ 0b00110, 0b01001, 0b00010, 0b00001, 0b01001, 0b00110 }, // 3
    .{ 0b00001, 0b01010, 0b01010, 0b01111, 0b00010, 0b00010 }, // 4
    .{ 0b01110, 0b01000, 0b01110, 0b00001, 0b01001, 0b00110 }, // 5
    .{ 0b00110, 0b01000, 0b01110, 0b01001, 0b01001, 0b00110 }, // 6
    .{ 0b01111, 0b01001, 0b00001, 0b00010, 0b00100, 0b00100 }, // 7
    .{ 0b00110, 0b01001, 0b00110, 0b01001, 0b01001, 0b00110 }, // 8
    .{ 0b00110, 0b01001, 0b01001, 0b00111, 0b00010, 0b00100 }, // 9
    .{ 0b00110, 0b01001, 0b01001, 0b01001, 0b01001, 0b00110 }, // 0
    .{ 0b00000, 0b00000, 0b00000, 0b00100, 0b01010, 0b00100 }, // .
    .{ 0b00000, 0b00110, 0b00110, 0b00100, 0b00000, 0b00100 }, // !
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b01000, 0b00100 }, // ,
    .{ 0b00000, 0b00100, 0b01000, 0b00000, 0b00000, 0b00000 }, // '
    .{ 0b00000, 0b01010, 0b01010, 0b00000, 0b00000, 0b00000 }, // \"
    .{ 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00000 }, // :
    .{ 0b00000, 0b01100, 0b01000, 0b01000, 0b01100, 0b00000 }, // [
    .{ 0b00000, 0b00110, 0b00010, 0b00010, 0b00110, 0b00000 }, // ]
    .{ 0b00000, 0b00010, 0b00100, 0b00100, 0b01000, 0b00000 }, // /
    .{ 0b00000, 0b00000, 0b01101, 0b10110, 0b00000, 0b00000 }, // ~
    .{ 0b00000, 0b00000, 0b00100, 0b01110, 0b00100, 0b00000 }, // +
    .{ 0b00110, 0b01011, 0b00010, 0b00100, 0b00000, 0b00100 }, // ?
    .{ 0b00000, 0b00000, 0b00000, 0b01110, 0b00000, 0b00000 }, // -
    .{ 0b00000, 0b00000, 0b01110, 0b00000, 0b01110, 0b00000 }, // =
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01110 }, // _
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }, //
};

/// Whole multiples of the cell height, never a fraction. `size` is what a
/// caller asked for; a bitmap has no hinting to soften the lie.
pub fn scaleFor(size: f32) u32 {
    const raw = size / @as(f32, @floatFromInt(glyph_h));
    if (!(raw > 1.0)) return 1;
    const s: u32 = @intFromFloat(@round(raw));
    return @max(1, s);
}

/// Table index for a codepoint, or null when this face cannot spell it.
///
/// Uppercase maps onto the lowercase glyph rather than being refused: the
/// diagnostic channel exists to be read, and "Error" folding to "error" costs
/// nothing an error message needs.
pub fn slot(cp: u32) ?usize {
    if (cp >= 'a' and cp <= 'z') return cp - 'a';
    if (cp >= 'A' and cp <= 'Z') return cp - 'A';
    if (cp >= '1' and cp <= '9') return 26 + (cp - '1');
    if (cp == '0') return 35;
    return switch (cp) {
        '.' => 36,
        '!' => 37,
        ',' => 38,
        '\'' => 39,
        '"' => 40,
        ':' => 41,
        '[' => 42,
        ']' => 43,
        '/' => 44,
        '~' => 45,
        '+' => 46,
        '?' => 47,
        '-' => 48,
        '=' => 49,
        '_' => 50,
        ' ' => 51,
        else => null,
    };
}

/// The rows to draw, with unknown codepoints resolved to `?`.
pub fn glyphFor(cp: u32) [glyph_h]u8 {
    if (cp == '\n' or cp == '\t' or cp == '\r') return .{0} ** glyph_h;
    return glyphs[slot(cp) orelse 47];
}

/// Rows this glyph sits below the top of the ink box, in whole cells.
///
/// The sheet this face was drawn from put every glyph in the same six rows, so
/// the letters with tails sat ON the baseline and the ones the source drew a
/// bit high stayed high -- `e` and `g` began a row above `c` and `o`, and `j p
/// q` had nowhere to descend to. This is the correction, and it is a number per
/// glyph rather than a redrawn table because the shapes are right and only
/// their placement is not.
///
/// It scales with `s` because it is measured in cells, not pixels: a drop of
/// one is one pixel at size 6 and six at size 36. That keeps the whole-multiple
/// rule `scaleFor` exists to enforce.
///
/// Uppercase folds to the same glyph, so it takes the same drop. Anything this
/// face cannot spell draws as `?`, which has no drop, so an unknown codepoint
/// resolves through the `else` like any other flat glyph.
pub fn dyOf(cp: u32) u32 {
    return switch (cp) {
        'e', 'E', 'g', 'G', 'y', 'Y' => 1,
        'j', 'J', 'p', 'P', 'q', 'Q' => 2,
        else => 0,
    };
}

/// Whether the codepoint is one this face can spell. Used by the measurement
/// test to prove the fold and the `?` are not the same answer.
pub fn spells(cp: u32) bool {
    return slot(cp) != null;
}

pub fn measure(bytes: []const u8, size: f32) elmz.TextMetrics {
    const s = scaleFor(size);
    var i: usize = 0;
    var n: u32 = 0;
    while (i < bytes.len) {
        const cp = cedar.decode(bytes, &i);
        // A line break is the caller's business: it splits lines and draws
        // them, so it contributes no width here and no glyph anywhere.
        if (cp == '\n') continue;
        n += advance;
    }
    // The measured height is the LINE box, not the ink box: an element sized to
    // the ink box would clip the descenders the drop table moves below it.
    const h: f32 = @floatFromInt(line_h * s);
    // The trailing gap is not ink, so it is not width. A label centred on a
    // measurement that included it sits one pixel left of centre.
    const w: f32 = if (n == 0) 0 else @floatFromInt((n - 1) * s);
    return .{
        .width = w,
        .height = h,
        .ascent = h,
        .descent = 0,
        .line_height = h + @as(f32, @floatFromInt(s)),
    };
}

/// Width of `bytes[0..index]`, on the same whole-cell grid `measure` uses.
/// Uniform advances make this arithmetic, and the trailing gap is not ink.
pub fn advanceTo(bytes: []const u8, size: f32, index: usize) f32 {
    const s = scaleFor(size);
    var i: usize = 0;
    var n: u32 = 0;
    const target = @min(index, bytes.len);
    while (i < target) {
        const cp = cedar.decode(bytes, &i);
        if (cp == '\n') continue;
        n += advance;
    }
    return if (n == 0) 0 else @floatFromInt((n - 1) * s);
}

/// The cell boundary nearest `x`, measured in cells rather than glyphs.
pub fn hitText(bytes: []const u8, size: f32, x: f32) usize {
    if (bytes.len == 0 or x <= 0) return 0;
    const s = scaleFor(size);
    var i: usize = 0;
    var n: u32 = 0;
    while (i < bytes.len) {
        const before = i;
        const cp = cedar.decode(bytes, &i);
        if (cp == '\n') continue;
        const b: f32 = if (n == 0) 0 else @floatFromInt((n - 1) * s);
        const e: f32 = @floatFromInt(((n + advance) - 1) * s);
        if (x <= (b + e) * 0.5) return before;
        n += advance;
    }
    return bytes.len;
}

/// Greedy wrap, and the advances are uniform, so "how many fit" is arithmetic
/// rather than a walk: k glyphs are `(k * advance - 1) * scale` wide.
/// A single glyph wider than the box still gets its own line, because a loop
/// that refuses to emit anything is a hang.
pub fn wrap(bytes: []const u8, size: f32, max_w: f32, out: [][]const u8) usize {
    if (out.len == 0) return 0;
    const s = scaleFor(size);
    const unit: f32 = @floatFromInt(advance * s);
    const gap: f32 = @floatFromInt(s);
    const per_line: usize = @max(1, @as(usize, @intFromFloat(@floor((max_w + gap) / unit))));

    var n: usize = 0;
    var at: usize = 0;
    while (at < bytes.len and n < out.len) : (n += 1) {
        while (at < bytes.len and (bytes[at] == ' ' or bytes[at] == '\n')) at += 1;
        if (at >= bytes.len) break;
        var end = @min(at + per_line, bytes.len);
        // Never split a codepoint: back up over continuation bytes.
        while (end < bytes.len and end > at and (bytes[end] & 0xC0) == 0x80) end -= 1;
        if (std.mem.indexOfScalar(u8, bytes[at..end], '\n')) |k| {
            out[n] = bytes[at .. at + k];
            at = at + k + 1;
            continue;
        }
        var broke = false;
        if (end < bytes.len) {
            var j = end;
            while (j > at) : (j -= 1) {
                if (bytes[j - 1] == ' ') {
                    out[n] = bytes[at .. j - 1];
                    at = j;
                    broke = true;
                    break;
                }
            }
        }
        if (broke) continue;
        out[n] = bytes[at..end];
        at = end;
    }
    return n;
}

const testing = std.testing;

test "the table is the charset it claims" {
    try testing.expectEqual(order.len, glyphs.len);
    try testing.expectEqual(@as(usize, 52), glyphs.len);
    // Every spellable codepoint resolves to its own row, so a typo in `order`
    // or in `slot` cannot pass by making two glyphs share an index.
    for (order, 0..) |ch, idx| {
        try testing.expectEqual(idx, slot(ch).?);
        try testing.expect(spells(ch));
    }
}

test "no two glyphs collide, and every one but space has ink" {
    // A hand-drawn table has exactly one failure mode that survives every other
    // check: a row copied or left as a placeholder. `l` was a bare full-height
    // stem -- `1` minus its flag -- for as long as nothing compared rows.
    for (glyphs, 0..) |g, i| {
        var ink: u16 = 0;
        for (g) |row| ink += row;
        if (order[i] == ' ') {
            try testing.expectEqual(@as(u16, 0), ink);
            continue;
        }
        try testing.expect(ink != 0);
        for (glyphs[i + 1 ..]) |other| {
            // No print on the failure path either: stderr is the build runner's
            // protocol channel under `zig build test`.
            try testing.expect(!std.mem.eql(u8, &g, &other));
        }
    }
}

test "uppercase folds and unsupported codepoints become a question mark" {
    try testing.expectEqual(slot('Q'), slot('q'));
    try testing.expectEqual(glyphFor('Q'), glyphFor('q'));
    try testing.expectEqual(glyphFor('?'), glyphFor(0x4e2d));
    try testing.expect(!spells(0x4e2d));
    try testing.expectEqual(glyphFor(' '), .{0} ** glyph_h);
}

test "widths are whole multiples of the advance, and the tail gap is not ink" {
    // 12pt is exactly two cells tall, so one cell of advance is 12 and the
    // ink of two glyphs is 11 -- the trailing gap is a gap, not width.
    try testing.expectEqual(@as(f32, 10), measure("a", 12).width);
    try testing.expectEqual(@as(f32, 22), measure("ab", 12).width);
    try testing.expectEqual(@as(f32, 0), measure("", 12).width);
    // The LINE box, not the ink box: two cells of scale, eight rows per cell.
    try testing.expectEqual(@as(f32, 16), measure("a", 12).height);
    try testing.expectEqual(@as(usize, 1), scaleFor(6));
    try testing.expectEqual(@as(usize, 2), scaleFor(11.9));
    try testing.expectEqual(@as(usize, 1), scaleFor(1));
}

test "a descender drops inside the line box and never past it" {
    // The drop is per glyph and in whole cells, so uppercase has to follow its
    // lowercase and everything else has to stay put.
    for ("egy") |ch| try testing.expectEqual(@as(u32, 1), dyOf(ch));
    for ("jpq") |ch| try testing.expectEqual(@as(u32, 2), dyOf(ch));
    for ("EGYJPQ") |ch| try testing.expectEqual(dyOf(ch + 32), dyOf(ch));
    for ("abchinorstuvwz0123456789?!-_ ") |ch| try testing.expectEqual(@as(u32, 0), dyOf(ch));
    // The check that makes the constant honest: the deepest ink in the table,
    // shifted by the deepest drop, still lands inside `line_h`. Get this wrong
    // and the descender is drawn below the element box and clipped away, which
    // looks exactly like a glyph that was never shifted.
    var deepest: usize = 0;
    for (order, 0..) |ch, i| {
        var last: usize = 0;
        for (glyphs[i], 0..) |row, gy| {
            if (row != 0) last = gy;
        }
        deepest = @max(deepest, last + dyOf(ch));
    }
    try testing.expect(deepest < line_h);
}

test "wrapping breaks on a space and never loses a word" {
    var buf: [8][]const u8 = undefined;
    const text = "font path is missing";
    const n = wrap(text, 12, 40, &buf); // three cells per line at 2x
    try testing.expect(n > 1);
    var seen: usize = 0;
    for (buf[0..n]) |line| {
        try testing.expect(measure(line, 12).width <= 40.5);
        seen += line.len;
    }
    try testing.expect(seen + n - 1 >= text.len);
}
