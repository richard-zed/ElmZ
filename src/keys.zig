//! Keyboard vocabulary: what a key press *is*, and how a chord is matched.
//!
//! Split out of `elmz.zig` for one concrete reason: `reducer.zig` needs `Key`,
//! `Mods` and `Named` to test text editing, and importing `elmz.zig` for three
//! pure types dragged the whole renderer into its module graph -- which made
//! `zig build test` collect elmz's 102 tests inside the reducer's binary and
//! report 117 for a file that owns 15.
//!
//! Nothing here touches a canvas, a tree, a theme or a frame. The whole file is
//! plain data and pure functions, so it can be tested -- and depended on --
//! without any of the library.

const std = @import("std");

/// Which modifier keys were held when a key event was produced.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false,
};

/// Keys worth naming, because binding to a raw code is how you get a shortcut
/// that quietly stops working on another layout. This is a convenience list,
/// not a filter: anything absent still arrives, in `Key.code`.
pub const Named = enum {
    enter,
    escape,
    tab,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// One key, described three ways because the three are not interchangeable.
///
/// `code` is the layout-dependent symbol -- what the key is LABELLED, and what
/// a shortcut wants: on Dvorak the physical C position produces 'j', and
/// Ctrl+Z means the label. `scancode` is physical POSITION, which is what
/// W-A-S-D movement wants so it stays put across layouts. `named` is the
/// common subset of both, so `update` does not compare magic numbers.
///
/// Typed text does NOT come from here. A dead-key accent, a compose sequence
/// or an IME commit has no single key to derive from, so text arrives as its
/// own event once a text field exists. A Ctrl chord produces no text at all --
/// that asymmetry is why both paths are needed rather than one.
///
/// All three are u32 (SDL's keycode, SDL's scancode, xkbcommon's keysym).
/// Narrowing this to u8 was not a simplification: SDLK_LEFT is 0x40000050, and
/// truncating it yields the character 'P'.
pub const Key = struct {
    named: ?Named = null,
    code: u32 = 0,
    scancode: u32 = 0,
    mods: Mods = .{},
    /// True for the extra presses a backend synthesises while the key is held.
    /// A flag rather than its own event type because the app cannot tell -- and
    /// must not care -- whether the platform or the runner timed the repeat.
    /// Wayland has no server-side repeat, so that answer does change per
    /// backend; a flag keeps it from leaking into every `update`.
    repeat: bool = false,
};

/// How a shortcut names its key.
///
/// Two spellings because they answer different questions. `ch` is the LABEL --
/// what Ctrl+S means, which on Dvorak is the key that types `o` -- and `named`
/// is the common set of named keys. A raw `code` is deliberately NOT bindable:
/// a shortcut bound to a physical position is the one that stops working the
/// day somebody switches layout.
pub const ShortcutKey = union(enum) {
    ch: u8,
    named: Named,

    /// So a call site reads `.key = ShortcutKey.char('s')`.
    pub fn char(c: u8) ShortcutKey {
        return .{ .ch = c };
    }
};

/// One binding. Declared on the app, comptime, so a collision is a build error.
pub fn Shortcut(comptime M: type) type {
    return struct {
        key: ShortcutKey,
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
        gui: bool = false,
        msg: M,
    };
}

/// Whether `k` is exactly the chord `sc` names.
///
/// Every modifier must match, including the absent ones: Ctrl+Shift+S is not
/// Ctrl+S, and a rule that ignored `shift` would make the two impossible to
/// tell apart. Pure, so the matching rule is testable without a window, a
/// runner or a frame.
pub fn shortcutMatches(sc: anytype, k: Key) bool {
    if (k.mods.ctrl != sc.ctrl) return false;
    if (k.mods.shift != sc.shift) return false;
    if (k.mods.alt != sc.alt) return false;
    if (k.mods.gui != sc.gui) return false;
    return switch (sc.key) {
        .ch => |c| blk: {
            if (k.code > 127) break :blk false;
            break :blk std.ascii.toLower(@as(u8, @intCast(k.code))) == std.ascii.toLower(c);
        },
        .named => |n| k.named == n,
    };
}

/// A binding with no command modifier is BARE: it types a character.
///
/// Shift does not count as a modifier here, because Shift+S is how a capital S
/// is typed -- treating it as a chord would make "select all" fire on a
/// keystroke someone meant as a letter.
pub fn isBareShortcut(sc: anytype) bool {
    return !sc.ctrl and !sc.alt and !sc.gui;
}

/// The message `k` should dispatch, or null when no binding claims it.
///
/// Bare bindings are skipped while a text field has focus, or every letter
/// typed into it would also run a command.
pub fn shortcutFor(comptime M: type, comptime list: anytype, k: Key, text_editing: bool) ?M {
    inline for (list) |sc| {
        // One combined condition rather than two `continue`s: `continue` inside
        // `inline for` is comptime control flow and does not belong in a
        // function the runtime calls.
        if (shortcutMatches(sc, k) and !(text_editing and isBareShortcut(sc))) {
            return sc.msg;
        }
    }
    return null;
}

/// Comptime guard: two commands on one chord is a build error, never a race
/// decided by whichever arm was written first.
pub fn checkShortcuts(comptime list: anytype) void {
    comptime {
        for (0..list.len) |i| {
            for (i + 1..list.len) |j| {
                const a = list[i];
                const b = list[j];
                if (a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and
                    a.gui == b.gui and std.meta.eql(a.key, b.key))
                {
                    @compileError("two shortcuts are bound to the same chord");
                }
            }
        }
    }
}
