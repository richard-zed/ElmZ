//! Line breaking (UAX #14), currently a deliberate subset.
//!
//! No font data is involved: whether a break may fall between two characters
//! depends only on their Unicode properties, so this module has no dependency
//! on Cedar and is tested as pure functions. The caller supplies widths; this
//! decides where the opportunities are.
//!
//! NOT CONFORMANT. Measured against the Unicode 18.0.0 LineBreakTest.txt
//! (19,346 cases) the subset below disagrees on ~58%. The gap is in Latin
//! punctuation (AI, BA, QU, IS), not CJK. Closing it means ~40 classes and a
//! generated pair table; until then this does not claim conformance.

const std = @import("std");

/// The standard has ~40 classes and ~30 pair rules. This is the subset that
/// decides whether CJK breaks in the right PLACES: runs of ideographs are
/// breakable, closing punctuation and small kana may not start a line, opening
/// punctuation may not end one, and a number is not split.
pub const BreakClass = enum { space, open, close, small, digit, ideo, other };

pub fn breakClass(cp: u32) BreakClass {
    return switch (cp) {
        ' ', '\t', 0x3000 => .space,
        '0'...'9', 0xFF10...0xFF19 => .digit,
        // Closing: no line may START with one of these (kinsoku).
        0x3001,
        0x3002, // 、。
        0x3009,
        0x300B,
        0x300D,
        0x300F,
        0x3011, // 〉》」』】
        0x3015,
        0x3017,
        0x3019,
        0x301B,
        0xFF01,
        0xFF09,
        0xFF1F,
        0xFF3D,
        0xFF5D, // ！）？］｝
        0xFF0C,
        0xFF0E,
        0xFF1A,
        0xFF1B, // ，．：；
        0xFF61,
        0xFF63,
        0xFF64,
        0x30FB,
        0x30FC, // ・ー
        0x2026,
        0x2025, // …‥
        => .close,
        // Opening: no line may END with one of these.
        0x3008,
        0x300A,
        0x300C,
        0x300E,
        0x3010, // 〈《「『【
        0x3014,
        0x3016,
        0x3018,
        0x301A,
        0xFF08,
        0xFF3B,
        0xFF5B, // （［｛
        => .open,
        // Small kana: belong to the syllable before them, never start a line.
        0x3041,
        0x3043,
        0x3045,
        0x3047,
        0x3049,
        0x3063,
        0x3083,
        0x3085,
        0x3087,
        0x308E,
        0x30A1,
        0x30A3,
        0x30A5,
        0x30A7,
        0x30A9,
        0x30C3,
        0x30E3,
        0x30E5,
        0x30E7,
        0x30EE,
        0xFF67...0xFF6F,
        => .small,
        else => if (isIdeographic(cp)) .ideo else .other,
    };
}

fn isIdeographic(cp: u32) bool {
    return (cp >= 0x2E80 and cp <= 0x303E) // radicals through CJK punctuation
    or (cp >= 0x3041 and cp <= 0x30FF) // kana
    or (cp >= 0x3400 and cp <= 0x4DBF) // extension A
    or (cp >= 0x4E00 and cp <= 0x9FFF) // unified ideographs
    or (cp >= 0xF900 and cp <= 0xFAFF) // compatibility ideographs
    or (cp >= 0xAC00 and cp <= 0xD7A3) // hangul syllables
    or (cp >= 0xFF01 and cp <= 0xFF60) // fullwidth forms
    or (cp >= 0x20000 and cp <= 0x2FA1F); // extensions B and beyond
}

/// May a line break fall BETWEEN these two characters? Permissive around
/// ideographs on either side, strict about the cases that make CJK look wrong
/// under a naive greedy loop.
pub fn canBreak(prev: BreakClass, cur: BreakClass) bool {
    if (cur == .close or cur == .small) return false;
    if (prev == .open) return false;
    if (prev == .digit and cur == .digit) return false;
    return prev == .ideo or cur == .ideo;
}

test "the CJK break classes refuse every kinsoku case" {
    const T = std.testing;
    // Closing punctuation and small kana may never begin a line.
    try T.expect(!canBreak(.ideo, breakClass(0x3002))); // 。 ideographic full stop
    try T.expect(!canBreak(.ideo, breakClass(0x3001))); // 、 ideographic comma
    try T.expect(!canBreak(.ideo, breakClass(0x3063))); // っ small tsu
    // Opening punctuation may never end one.
    try T.expect(!canBreak(breakClass(0x300C), .ideo)); // 「
    // A digit run stays whole.
    try T.expect(!canBreak(.digit, .digit));
    // Between ideographs is exactly where a break belongs, which is the whole
    // reason a space-only rule was wrong for this text.
    try T.expect(canBreak(.ideo, breakClass(0x4E00))); // 一
    try T.expect(canBreak(breakClass(0x65E5), breakClass(0x672C))); // 日本
    // And the Latin path is unchanged: two letters are not a break.
    try T.expect(!canBreak(.other, .other));
}
