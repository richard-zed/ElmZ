//! Keyboard vocabulary: what a key press *is*, and how a chord is matched.

const std = @import("std");

/// Which modifier keys were held when a key event was produced.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false,
};

/// Keys worth naming, because binding to a raw code is how you get a shortcut that quietly
/// stops working on another layout.
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
pub const Key = struct {
    named: ?Named = null,
    code: u32 = 0,
    scancode: u32 = 0,
    mods: Mods = .{},
    /// True for the extra presses a backend synthesises while the key is held.
    repeat: bool = false,
};

/// How a shortcut names its key. Two spellings because they answer different questions.
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
pub fn isBareShortcut(sc: anytype) bool {
    return !sc.ctrl and !sc.alt and !sc.gui;
}

/// The message `k` should dispatch, or null when no binding claims it.
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

/// Comptime guard: two commands on one chord is a build error, never a race decided by
/// whichever arm was written first.
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
