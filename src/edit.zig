//! Text editing, as a pure state-to-state function.
//!
//! The Model owns the text, the caret and the selection. This file owns the
//! RULES that move them: what backspace does to a selection, where the caret
//! lands after a vertical move, which byte a "left arrow" jumps to. Those rules
//! are identical in every text box ever written, and the reason to centralise
//! them is not tidiness -- it is that leaving them to each app means the same
//! off-by-one is written N times and fixed zero times.
//!
//! Everything here is a plain function over `*TextEdit`. No frame, no widget,
//! no renderer, no font. That is what makes it testable without a window, and
//! it is why the widget can be a thin painter over this.
//!
//! WHY THE CALLER PASSES AN ALLOCATOR: an edit produces a new string, and the
//! allocator must be one that OUTLIVES THE FRAME. `Model.name.value` is read
//! every frame: if it pointed into `Ui`'s per-frame arena it would dangle the
//! moment the next frame began, and the symptom would be text that mutates
//! while the user is not typing. Pass the app's allocator, or a Model-owned
//! arena that is reset only when the document itself is replaced.
//!
//! BYTES, NOT GRAPHEMES: every boundary below is a UTF-8 codepoint boundary, so
//! an edit can never split a multi-byte character. A combining sequence (`e`
//! followed by U+0301) is still two codepoints and backspace removes the accent
//! first. Grapheme clustering needs the Unicode tables; it is a real gap and it
//! is stated rather than hidden.

const std = @import("std");
const elmz = @import("elmz.zig");

const Allocator = std.mem.Allocator;
const Key = elmz.Key;

/// A selection is an anchor plus wherever the caret is now.
///
/// The head is NOT stored: it is `caret`. Storing both invites the two to
/// disagree, and every operation here would then have to pick a winner.
pub const TextEdit = struct {
    value: []const u8 = "",
    /// Byte offset of the insertion point, always on a codepoint boundary.
    caret: usize = 0,
    /// Where the selection started. Null means "no selection"; equal to the
    /// caret also means no selection, so a click-then-click never leaves a
    /// zero-width range behind.
    anchor: ?usize = null,
    /// Column to aim at for a run of vertical moves, so that driving the caret
    /// down through short lines and back does not walk it leftwards. Cleared by
    /// anything horizontal or by an edit.
    goal: ?usize = null,

    pub const Range = struct { start: usize, end: usize };

    /// The selected byte range, or null when nothing is selected.
    pub fn selection(self: TextEdit) ?Range {
        const a = self.anchor orelse return null;
        const lo = @min(a, self.caret);
        const hi = @max(a, self.caret);
        if (lo == hi) return null;
        return .{ .start = lo, .end = hi };
    }

    /// The selected bytes, or null. Borrowed from `value`.
    pub fn selectedText(self: TextEdit) ?[]const u8 {
        const r = self.selection() orelse return null;
        return self.value[r.start..r.end];
    }

    /// Clamp the caret into the string and onto a codepoint boundary.
    ///
    /// Worth calling whenever `value` is set from outside -- a restored draft,
    /// a load, a programmatic set -- because a caret left mid-codepoint makes
    /// every subsequent edit corrupt the text rather than merely look wrong.
    pub fn normalize(self: *TextEdit) void {
        if (self.caret > self.value.len) self.caret = self.value.len;
        while (self.caret > 0 and self.caret < self.value.len and isCont(self.value[self.caret])) {
            self.caret -= 1;
        }
        if (self.anchor) |a| {
            var n = @min(a, self.value.len);
            while (n > 0 and n < self.value.len and isCont(self.value[n])) n -= 1;
            self.anchor = if (n == self.caret) null else n;
        }
    }

    pub fn selectAll(self: *TextEdit) void {
        self.anchor = if (self.value.len == 0) null else 0;
        self.caret = self.value.len;
        self.goal = null;
    }

    /// Put the caret somewhere. `extend` is shift: keep the anchor so a
    /// selection grows or shrinks, otherwise drop it.
    pub fn moveTo(self: *TextEdit, pos: usize, extend: bool) bool {
        const p = @min(pos, self.value.len);
        if (p == self.caret and (extend or self.anchor == null or self.anchor.? == p)) return false;
        if (extend) {
            if (self.anchor == null) self.anchor = self.caret;
        } else {
            self.anchor = null;
        }
        self.caret = p;
        self.goal = null;
        return true;
    }

    /// The whole of the editing surface: one key in, a changed flag out.
    ///
    /// Returns FALSE for any key it does not own, which is not a failure --
    /// it is how Tab reaches the focus ring and Escape reaches the app. The
    /// app's hook is `if (m.field.handleKey(gpa, k)) return .edited;`.
    pub fn handleKey(self: *TextEdit, gpa: Allocator, k: Key) bool {
        const shift = k.mods.shift;
        const word = k.mods.ctrl;

        if (k.named) |n| switch (n) {
            .enter => return self.insertText(gpa, "\n"),
            .backspace => return self.backspace(gpa),
            .delete => return self.deleteForward(gpa),
            // With a selection and no shift, one press collapses it rather
            // than stepping from the caret: the careted end is where the user
            // let go, and it is almost never the end they meant.
            .left => {
                if (!shift) if (self.selection()) |r| return self.moveTo(r.start, false);
                return self.moveTo(if (word) prevWord(self.value, self.caret) else prevBoundary(self.value, self.caret), shift);
            },
            .right => {
                if (!shift) if (self.selection()) |r| return self.moveTo(r.end, false);
                return self.moveTo(if (word) nextWord(self.value, self.caret) else nextBoundary(self.value, self.caret), shift);
            },
            .up => return self.moveVertical(-1, shift),
            .down => return self.moveVertical(1, shift),
            .home => {
                const target = if (word) 0 else lineStart(self.value, self.caret);
                return self.moveTo(target, shift);
            },
            .end => {
                const target = if (word) self.value.len else lineEnd(self.value, self.caret);
                return self.moveTo(target, shift);
            },
            // Tab, Escape, PageUp/Down and the function keys belong to the
            // runtime or the app. Saying so is the point of the null return.
            else => return false,
        };

        // Ctrl+A, the one chord worth owning here: it is pure selection, needs
        // no clipboard, and every text box has it. Copy/cut/paste are the
        // app's, because they need a seam this file cannot reach.
        if (k.mods.ctrl or k.mods.gui) {
            if (k.code == 'a') {
                const covered = if (self.selection()) |r|
                    r.start == 0 and r.end == self.value.len
                else
                    false;
                self.selectAll();
                return !covered;
            }
        }
        return false;
    }

    /// Typed text, from the text-input event. Never from a key: a dead key, a
    /// compose sequence and an IME commit have no single key to derive from.
    pub fn typeBytes(self: *TextEdit, gpa: Allocator, bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        // A carriage return is dropped: some backends report Enter as "\r",
        // and the key event already inserts the newline. Everything else --
        // including a genuine '\n' from pasted-or-equivalent input -- goes in.
        if (std.mem.indexOfScalar(u8, bytes, '\r') == null) {
            return self.insertText(gpa, bytes);
        }
        var clean: [256]u8 = undefined;
        var n: usize = 0;
        for (bytes) |b| {
            if (b == '\r') continue;
            if (n == clean.len) break;
            clean[n] = b;
            n += 1;
        }
        if (n == 0) return false;
        return self.insertText(gpa, clean[0..n]);
    }

    pub fn backspace(self: *TextEdit, gpa: Allocator) bool {
        if (self.selection()) |r| return self.splice(gpa, r.start, r.end, "");
        if (self.caret == 0) return false;
        const start = prevBoundary(self.value, self.caret);
        return self.splice(gpa, start, self.caret, "");
    }

    pub fn deleteForward(self: *TextEdit, gpa: Allocator) bool {
        if (self.selection()) |r| return self.splice(gpa, r.start, r.end, "");
        if (self.caret >= self.value.len) return false;
        const end = nextBoundary(self.value, self.caret);
        return self.splice(gpa, self.caret, end, "");
    }

    /// Replace the selection (or insert at the caret). Paste is this.
    pub fn insertText(self: *TextEdit, gpa: Allocator, bytes: []const u8) bool {
        if (self.selection()) |r| return self.splice(gpa, r.start, r.end, bytes);
        const at = self.caret;
        return self.splice(gpa, at, at, bytes);
    }

    /// Delete the selection without inserting anything. Cut is this plus the
    /// clipboard write the app does.
    pub fn deleteSelection(self: *TextEdit, gpa: Allocator) bool {
        const r = self.selection() orelse return false;
        return self.splice(gpa, r.start, r.end, "");
    }

    /// Replace bytes `start..end` with `ins`, then place the caret after it.
    ///
    /// The single point where the string is rebuilt, so every operation above
    /// inherits the same caret and selection rules instead of each one setting
    /// them slightly differently.
    fn splice(self: *TextEdit, gpa: Allocator, start: usize, end: usize, ins: []const u8) bool {
        if (start == end and ins.len == 0) return false;
        const s = @min(start, self.value.len);
        const e = @min(end, self.value.len);
        const new_len = s + ins.len + (self.value.len - e);
        const out = gpa.alloc(u8, new_len) catch return false;
        @memcpy(out[0..s], self.value[0..s]);
        @memcpy(out[s .. s + ins.len], ins);
        @memcpy(out[s + ins.len ..], self.value[e..]);
        self.value = out;
        self.caret = s + ins.len;
        self.anchor = null;
        self.goal = null;
        return true;
    }

    /// Move one logical line up or down, keeping the column goal.
    ///
    /// Logical lines, not visual ones: wrapping is a font question and this
    /// file has no font. A wrapped field should call `moveVerticalIn` with the
    /// line starts the renderer gave it.
    pub fn moveVertical(self: *TextEdit, dir: i2, extend: bool) bool {
        if (dir < 0) {
            const cur = lineStart(self.value, self.caret);
            if (cur == 0) return self.moveTo(0, extend);
            const prev = lineStart(self.value, cur - 1);
            return self.moveToColumn(prev, lineEnd(self.value, prev) - prev, extend);
        }
        const cur_end = lineEnd(self.value, self.caret);
        if (cur_end >= self.value.len) return self.moveTo(self.value.len, extend);
        const next = cur_end + 1;
        return self.moveToColumn(next, lineEnd(self.value, next) - next, extend);
    }

    /// The same move against an arbitrary line table, for a wrapped field.
    /// `lines` is sorted line-start offsets and must begin with 0.
    pub fn moveVerticalIn(self: *TextEdit, lines: []const usize, dir: i2, extend: bool) bool {
        if (lines.len == 0) return self.moveVertical(dir, extend);
        const idx = lineOf(lines, self.caret);
        const target = if (dir < 0)
            (if (idx == 0) return self.moveTo(0, extend) else idx - 1)
        else
            (if (idx + 1 >= lines.len) return self.moveTo(self.value.len, extend) else idx + 1);
        const start = lines[target];
        const end = if (target + 1 < lines.len) lines[target + 1] else self.value.len;
        return self.moveToColumn(start, end - start, extend);
    }

    fn moveToColumn(self: *TextEdit, line_start: usize, line_len: usize, extend: bool) bool {
        if (self.goal == null) self.goal = self.caret - lineStart(self.value, self.caret);
        const want = @min(self.goal.?, line_len);
        return self.moveTo(line_start + want, extend);
    }
};

// ---------------------------------------------------------------------------
// byte boundaries
// ---------------------------------------------------------------------------

fn isCont(b: u8) bool {
    return (b & 0xc0) == 0x80;
}

/// The start of the codepoint before `i`.
pub fn prevBoundary(v: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var n = i - 1;
    while (n > 0 and isCont(v[n])) n -= 1;
    return n;
}

/// The start of the codepoint after `i`.
pub fn nextBoundary(v: []const u8, i: usize) usize {
    if (i >= v.len) return v.len;
    var n = i + 1;
    while (n < v.len and isCont(v[n])) n += 1;
    return n;
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n';
}

pub fn prevWord(v: []const u8, i: usize) usize {
    var n = i;
    while (n > 0 and isSpace(v[n - 1])) n -= 1;
    while (n > 0 and !isSpace(v[n - 1])) n = prevBoundary(v, n);
    return n;
}

pub fn nextWord(v: []const u8, i: usize) usize {
    var n = i;
    while (n < v.len and !isSpace(v[n])) n = nextBoundary(v, n);
    while (n < v.len and isSpace(v[n])) n += 1;
    return n;
}

/// Offset of the first byte of the line containing `i`.
pub fn lineStart(v: []const u8, i: usize) usize {
    var n = @min(i, v.len);
    while (n > 0) : (n -= 1) {
        if (v[n - 1] == '\n') return n;
    }
    return 0;
}

/// Offset of the '\n' ending the line containing `i`, or `v.len`.
pub fn lineEnd(v: []const u8, i: usize) usize {
    var n = @min(i, v.len);
    while (n < v.len) : (n += 1) {
        if (v[n] == '\n') return n;
    }
    return v.len;
}

fn lineOf(lines: []const usize, caret: usize) usize {
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        if (lines[i] <= caret) return i;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    t: TextEdit = .{},

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }
    fn gpa(self: *Harness) Allocator {
        return self.arena.allocator();
    }
    fn key(self: *Harness, n: elmz.Named, mods: elmz.Mods) bool {
        return self.t.handleKey(self.gpa(), .{ .named = n, .mods = mods });
    }
    fn typing(self: *Harness, bytes: []const u8) bool {
        return self.t.typeBytes(self.gpa(), bytes);
    }
};

test "typing inserts at the caret and carries it along" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expect(h.typing("helo"));
    try testing.expectEqualStrings("helo", h.t.value);
    try testing.expectEqual(@as(usize, 4), h.t.caret);

    // Put the caret back over the 'o' and type the missing letter.
    _ = h.t.moveTo(3, false);
    try testing.expect(h.typing("l"));
    try testing.expectEqualStrings("hello", h.t.value);
    try testing.expectEqual(@as(usize, 4), h.t.caret);
}

test "backspace at the start of the text does nothing at all" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expect(!h.key(.backspace, .{}));
    try testing.expectEqualStrings("", h.t.value);

    _ = h.typing("ab");
    _ = h.t.moveTo(0, false);
    try testing.expect(!h.key(.backspace, .{}));
    try testing.expectEqualStrings("ab", h.t.value);
}

test "backspace removes one whole codepoint, never half of one" {
    var h = Harness.init();
    defer h.deinit();
    // 'é' is two bytes, '🙂' is four.
    try testing.expect(h.typing("aé🙂"));
    try testing.expectEqual(@as(usize, 7), h.t.value.len);

    try testing.expect(h.key(.backspace, .{}));
    try testing.expectEqualStrings("aé", h.t.value);

    try testing.expect(h.key(.backspace, .{}));
    try testing.expectEqualStrings("a", h.t.value);
    try testing.expect(std.unicode.utf8ValidateSlice(h.t.value));
}

test "backspace with a selection removes the selection, not one more character" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("abcdef");
    _ = h.t.moveTo(1, false);
    _ = h.t.moveTo(4, true); // select "bcd"
    try testing.expectEqualStrings("bcd", h.t.selectedText().?);

    try testing.expect(h.key(.backspace, .{}));
    try testing.expectEqualStrings("aef", h.t.value);
    try testing.expectEqual(@as(usize, 1), h.t.caret);
    try testing.expect(h.t.selection() == null);
}

test "delete at the end of a line joins the next line onto it" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("one\ntwo");
    _ = h.t.moveTo(3, false); // just before the newline

    try testing.expect(h.key(.delete, .{}));
    try testing.expectEqualStrings("onetwo", h.t.value);
    try testing.expectEqual(@as(usize, 3), h.t.caret); // delete does not move the caret
}

test "a plain left arrow collapses a selection to its start" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("abcdef");
    _ = h.t.moveTo(1, false);
    _ = h.t.moveTo(4, true);
    try testing.expect(h.t.selection() != null);

    // One press of left: the selection is gone and the caret sits at its start.
    try testing.expect(h.key(.left, .{}));
    try testing.expect(h.t.selection() == null);
    try testing.expectEqual(@as(usize, 1), h.t.caret);

    // A second press moves from there, as it must.
    try testing.expect(h.key(.left, .{}));
    try testing.expectEqual(@as(usize, 0), h.t.caret);
}

test "shift arrows grow a selection and shrink it back through the anchor" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("abcdef");
    _ = h.t.moveTo(2, false);

    const shift: elmz.Mods = .{ .shift = true };
    _ = h.key(.right, shift);
    _ = h.key(.right, shift);
    try testing.expectEqualStrings("cd", h.t.selectedText().?);
    try testing.expectEqual(@as(usize, 4), h.t.caret);

    _ = h.key(.left, shift);
    try testing.expectEqualStrings("c", h.t.selectedText().?);

    // Back past the anchor: the selection flips sides rather than growing
    // backwards, which is what every editor does and what a naive
    // `end - start` implementation gets wrong.
    _ = h.key(.left, shift);
    _ = h.key(.left, shift);
    try testing.expectEqualStrings("a", h.t.selectedText().?);
    try testing.expectEqual(@as(usize, 1), h.t.caret);
}

test "up and down keep the column they were aiming at" {
    var h = Harness.init();
    defer h.deinit();
    // Column 4 is past the end of the short middle line.
    _ = h.typing("abcde\nab\nabcde");
    _ = h.t.moveTo(4, false);

    try testing.expect(h.key(.down, .{}));
    try testing.expectEqual(@as(usize, 8), h.t.caret); // clamped to "ab"

    // The goal was remembered, so coming back lands at column 4 again rather
    // than at column 2.
    try testing.expect(h.key(.down, .{}));
    try testing.expectEqual(@as(usize, 15), h.t.caret); // col 4 of "abcde"

    try testing.expect(h.key(.up, .{}));
    try testing.expectEqual(@as(usize, 8), h.t.caret);
    try testing.expect(h.key(.up, .{}));
    try testing.expectEqual(@as(usize, 4), h.t.caret);
}

test "home and end are the line, unless ctrl says the document" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("one\ntwo\nthree");
    _ = h.t.moveTo(6, false); // inside "two"

    _ = h.key(.home, .{});
    try testing.expectEqual(@as(usize, 4), h.t.caret);
    _ = h.key(.end, .{});
    try testing.expectEqual(@as(usize, 7), h.t.caret);

    const ctrl: elmz.Mods = .{ .ctrl = true };
    _ = h.key(.home, ctrl);
    try testing.expectEqual(@as(usize, 0), h.t.caret);
    _ = h.key(.end, ctrl);
    try testing.expectEqual(@as(usize, 13), h.t.caret);
}

test "ctrl arrows move a word at a time" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("one two  three");
    _ = h.t.moveTo(13, false); // end of "three"

    const ctrl: elmz.Mods = .{ .ctrl = true };
    _ = h.key(.left, ctrl);
    try testing.expectEqual(@as(usize, 9), h.t.caret); // start of "three"
    _ = h.key(.left, ctrl);
    try testing.expectEqual(@as(usize, 4), h.t.caret); // start of "two"
    _ = h.key(.right, ctrl);
    try testing.expectEqual(@as(usize, 9), h.t.caret);
}

test "enter splits a line and typing into a selection replaces it" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("abab");
    _ = h.t.moveTo(2, false);
    _ = h.key(.enter, .{});
    try testing.expectEqualStrings("ab\nab", h.t.value);
    try testing.expectEqual(@as(usize, 3), h.t.caret);

    h.t.selectAll();
    try testing.expectEqualStrings("ab\nab", h.t.selectedText().?);
    _ = h.typing("x");
    try testing.expectEqualStrings("x", h.t.value);
    try testing.expectEqual(@as(usize, 1), h.t.caret);
    try testing.expect(h.t.selection() == null);
}

test "ctrl+a selects everything, once" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("hello");
    const ctrl: elmz.Mods = .{ .ctrl = true };

    try testing.expect(h.t.handleKey(h.gpa(), .{ .code = 'a', .mods = ctrl }));
    try testing.expectEqualStrings("hello", h.t.selectedText().?);

    // Already all selected: no repaint to bill.
    try testing.expect(!h.t.handleKey(h.gpa(), .{ .code = 'a', .mods = ctrl }));
}

test "keys that are not ours are refused, not swallowed" {
    var h = Harness.init();
    defer h.deinit();
    _ = h.typing("x");
    for ([_]elmz.Named{ .tab, .escape, .page_up, .page_down, .f5 }) |n| {
        try testing.expect(!h.key(n, .{}));
    }
    // ...and the text is untouched by any of them.
    try testing.expectEqualStrings("x", h.t.value);
}

test "a caret left mid-codepoint is pulled back to a boundary" {
    var h = Harness.init();
    defer h.deinit();
    h.t.value = "aé";
    h.t.caret = 2; // second byte of 'é'
    h.t.normalize();
    try testing.expectEqual(@as(usize, 1), h.t.caret);
}

test "a carriage return from a text event never reaches the document" {
    var h = Harness.init();
    defer h.deinit();
    // Some backends report Enter as "\r"; the key event already inserts the
    // newline, so a CR would double it.
    try testing.expect(!h.typing("\r"));
    try testing.expectEqualStrings("", h.t.value);

    try testing.expect(h.typing("a\rb"));
    try testing.expectEqualStrings("ab", h.t.value);
}
