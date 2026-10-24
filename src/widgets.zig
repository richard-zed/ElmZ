//! Widgets: the named controls, and the options structs they take.
//!
//! Split out of `elmz.zig` so the file that owns the tree, layout and paint
//! stops growing every time a control is added. A builder here is an ordinary
//! `Element` in a shape the library happens to know how to drive -- the layout
//! engine never learns that a select exists.
//!
//! ONE-LINE FORWARDERS IN `Ui`. `usingnamespace` is gone, so `ui.select(...)`
//! cannot be spliced in from this file; each builder is forwarded by a single
//! line in the `Ui` body instead. Call sites are unchanged.
//!
//! WHY `anytype` FOR `ui` AND `o`: `Ui` is generic over the app's Msg (`M`), and
//! the option structs capture `M` (`msg: M`, `[]const Choice(M)`), so this file
//! cannot name them concretely. The forwarder is what carries the real types;
//! the bodies only need to reach through.

const std = @import("std");
const elmz = @import("elmz.zig");

pub fn SliderOpts(comptime M: type) type {
    return struct {
        key: u64,
        /// Into the Model, not the arena: a drag outlives the frame that
        /// started it, and app state is the one thing that does.
        value: *f32,
        min: f32 = 0,
        max: f32 = 1,
        /// null = continuous. Allowed, never enforced: a drag quantises as
        /// it goes, and a click is a nudge of one step toward the pointer.
        step: ?f32 = null,
        orientation: elmz.Orientation = .horizontal,
        msg: M,
        /// Travel along the long axis.
        length: f32 = 120,
        /// Thickness of the TRACK. The knob is twice this, and the hit
        /// rect is the knob's diameter.
        thickness: f32 = 6,
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        disabled: bool = false,
    };
}

/// A value control: track, filled portion and knob, composed from rects
/// because none of the three is a primitive worth adding.
///
/// The value is read at view time, so every child's geometry is known
/// before layout. None of the children sets `on_press` or `focusable`,
/// so none of them records a hit region and the stack's own region is
/// the only claim on the rect -- which is why composing cannot create a
/// z-order argument against the pointers that are meant to hit it.
///
/// The hit rect is the KNOB's diameter in the thin axis, not the
/// track's thickness. A 6px track is ungrabbable otherwise, and the
/// runtime drags whatever region it is given, so widening the region is
/// the whole fix.
pub fn slider(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    const span = o.max - o.min;
    const raw: f32 = if (span == 0) 0 else (o.value.* - o.min) / span;
    // clamp, not @min/@max by hand: it maps NaN to a bound instead of
    // letting it through, and a NaN here would place the knob and the
    // fill at a coordinate the rasteriser has to defend against.
    const f = std.math.clamp(raw, 0, 1);
    const d = o.thickness * 2;
    const inset = (d - o.thickness) / 2;
    const along = o.length * f;
    const knob_max = @max(o.length - d, 0);

    const track = ui.rect(.{
        .width = if (o.orientation == .horizontal) o.length else o.thickness,
        .height = if (o.orientation == .horizontal) o.thickness else o.length,
        .style = .{ .bg = ui.theme.control, .radius = o.thickness / 2 },
    });
    const fill = ui.rect(.{
        .width = if (o.orientation == .horizontal) along else o.thickness,
        .height = if (o.orientation == .horizontal) o.thickness else along,
        .style = .{ .bg = ui.theme.accent, .radius = o.thickness / 2 },
    });
    const knob = ui.rect(.{
        .width = d,
        .height = d,
        .style = .{ .bg = ui.theme.bg, .border = ui.theme.border, .radius = d / 2 },
    });

    switch (o.orientation) {
        // Vertical is INVERTED: a fader is loudest at the top, so a
        // control that grew upward but increased downward would be the
        // surprising one.
        .horizontal => {
            track.offset = .{ 0, inset };
            fill.offset = .{ 0, inset };
            knob.offset = .{ std.math.clamp(along - d / 2, 0, knob_max), 0 };
        },
        .vertical => {
            track.offset = .{ inset, 0 };
            fill.offset = .{ inset, o.length - along };
            knob.offset = .{ 0, std.math.clamp(o.length - along - d / 2, 0, knob_max) };
        },
    }

    const root = ui.stack(.{
        .children = &.{ track, fill, knob },
        .width = if (o.orientation == .horizontal) o.length else d,
        .height = if (o.orientation == .horizontal) d else o.length,
    });
    root.key = o.key;
    root.margin_left = o.margin_left;
    root.margin_right = o.margin_right;
    root.margin_top = o.margin_top;
    root.margin_bottom = o.margin_bottom;
    root.disabled = o.disabled;
    // A key plus `focusable` is what makes the region exist at all;
    // without them the payload would never reach the runtime.
    root.focusable = true;
    root.widget = ui.payload(.{ .slider = .{
        .value = o.value,
        .min = o.min,
        .max = o.max,
        .step = o.step,
        .orientation = o.orientation,
        .msg = o.msg,
    } });
    return root;
}

pub fn SelectOpts(comptime M: type) type {
    return struct {
        key: u64,
        open: bool,
        selected: u16,
        /// A pointer into the Model so hover, arrows and typeahead write one
        /// number. Two copies would let the highlight disagree with what
        /// Enter activates.
        active: *?u16,
        options: []const elmz.Choice(M),
        /// Emitted by the closed field, to toggle.
        msg: M,
        /// Shows when nothing is selected, and when `selected` is out of
        /// range -- which is a state a caller can reach without meaning to.
        placeholder: []const u8 = "",
        size: f32 = 16,
        width: ?f32 = null,
        style: elmz.Style = .{},
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        disabled: bool = false,
        hover_bg: ?elmz.Fill = null,
        press_bg: ?elmz.Fill = null,
    };
}

/// A collapsed list of options. The field is a button because that is
/// what it is: a focusable, clickable box showing the current value.
/// Placement, dismissal and typeahead belong to the runtime popup
/// layer, which needs the anchor's real laid-out rect -- something
/// `view` cannot know, because layout runs after `view` returns.
pub fn select(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    const label = if (o.selected < o.options.len)
        o.options[o.selected].label
    else
        o.placeholder;
    const e = ui.button(.{
        .label = label,
        .msg = o.msg,
        .size = o.size,
        .width = o.width,
        .style = o.style,
        .margin_left = o.margin_left,
        .margin_right = o.margin_right,
        .margin_top = o.margin_top,
        .margin_bottom = o.margin_bottom,
        .disabled = o.disabled,
        .hover_bg = o.hover_bg,
        .press_bg = o.press_bg,
    });
    e.key = o.key;
    e.focusable = true;
    e.widget = ui.payload(.{ .select = .{
        .open = o.open,
        .selected = o.selected,
        .active = o.active,
        .options = o.options,
        .msg = o.msg,
    } });
    return e;
}

pub fn MenuOpts(comptime M: type) type {
    return struct {
        key: u64,
        /// The trigger's own caption. `Widget.menu` deliberately carries no
        /// label: a menu is commands plus the button that reveals them, and
        /// the caption belongs to the button.
        label: []const u8,
        open: bool,
        active: *?u16,
        items: []const elmz.Choice(M),
        toggle: M,
        size: f32 = 16,
        width: ?f32 = null,
        style: elmz.Style = .{},
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        disabled: bool = false,
        hover_bg: ?elmz.Fill = null,
        press_bg: ?elmz.Fill = null,
    };
}

/// The menu node IS its trigger, so its laid-out rect is the popup's
/// anchor with no cross-node key lookup and no "anchor is not in this
/// frame" case. Same rule as select, different geometry: a menu drops
/// below its trigger and flips, where a select grows centred on field.
pub fn menu(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    const e = ui.button(.{
        .label = o.label,
        .msg = o.toggle,
        .size = o.size,
        .width = o.width,
        .style = o.style,
        .margin_left = o.margin_left,
        .margin_right = o.margin_right,
        .margin_top = o.margin_top,
        .margin_bottom = o.margin_bottom,
        .disabled = o.disabled,
        .hover_bg = o.hover_bg,
        .press_bg = o.press_bg,
    });
    e.key = o.key;
    e.focusable = true;
    e.widget = ui.payload(.{ .menu = .{
        .open = o.open,
        .active = o.active,
        .items = o.items,
        .toggle = o.toggle,
    } });
    return e;
}

pub const ControlKind = enum { checkbox, radio, toggle };

pub fn ControlOpts(comptime M: type) type {
    return struct {
        key: u64,
        label: []const u8,
        kind: ControlKind = .checkbox,
        /// Drawn from the Model, never held by the widget: a control that
        /// remembered its own state would disagree with the value the app
        /// fed back on the next frame.
        checked: bool,
        /// Emitted on activation. The Model flips `checked`; nothing here
        /// does, so the same builder works for a value derived from
        /// somewhere else entirely.
        msg: M,
        /// Set membership for a radio. Nothing reads it at paint time -- it
        /// exists so a later roving group can find its members without
        /// needing a container element to hang them on.
        group: u16 = 0,
        box: f32 = 16,
        gap: f32 = 8,
        size: f32 = 14,
        style: elmz.Style = .{},
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
    };
}

/// Checkbox, radio and switch: one builder because the three differ in
/// shape and in nothing else. All three take `checked` in and emit a
/// message out, so none of them owns state.
///
/// The WHOLE ROW is the hit region -- box, gap and label -- because a
/// 16px box is a small target and the label is what the reader is
/// actually aiming at. That is why the row carries the key and the
/// message rather than the box.
pub fn control(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    const Elem = @TypeOf(ui.*).Elem;
    const th = ui.theme;
    const mark = if (o.checked) th.accent else th.control;
    const box: *Elem = switch (o.kind) {
        .checkbox => blk: {
            const outer = ui.rect(.{
                .width = o.box,
                .height = o.box,
                .style = .{ .bg = mark, .border = th.border, .radius = 3 },
            });
            if (!o.checked) break :blk outer;
            // A filled square alone reads as "loud" without saying what
            // it is. The tick is a square in the page colour for now --
            // at 16px the silhouette is the whole legibility budget, and
            // a real check needs path data this library does not have.
            const tick = o.box * 0.5;
            // `offset` is on the Element, not on RectOpts: it is
            // placement, and a rect builder that took it would be
            // deciding where its parent puts it.
            const mark_e = ui.rect(.{
                .width = tick,
                .height = tick,
                .style = .{ .bg = th.bg, .radius = 1 },
            });
            mark_e.offset = .{ (o.box - tick) * 0.5, (o.box - tick) * 0.5 };
            break :blk ui.stack(.{ .width = o.box, .height = o.box, .children = &.{ outer, mark_e } });
        },
        .radio => blk: {
            const outer = ui.rect(.{
                .width = o.box,
                .height = o.box,
                .style = .{
                    .bg = th.control,
                    .border = if (o.checked) th.accent else th.border,
                    .radius = o.box * 0.5,
                },
            });
            if (!o.checked) break :blk outer;
            const dot = o.box * 0.4;
            const dot_e = ui.rect(.{
                .width = dot,
                .height = dot,
                .style = .{ .bg = th.accent, .radius = dot * 0.5 },
            });
            dot_e.offset = .{ (o.box - dot) * 0.5, (o.box - dot) * 0.5 };
            break :blk ui.stack(.{ .width = o.box, .height = o.box, .children = &.{ outer, dot_e } });
        },
        .toggle => blk: {
            const w = o.box * 2;
            const knob = o.box - 4;
            const track = ui.rect(.{
                .width = w,
                .height = o.box,
                .style = .{ .bg = mark, .border = th.border, .radius = o.box * 0.5 },
            });
            // The knob travels rather than the track changing shape: a
            // track that grew would move the label every time the value
            // flipped, which is the one thing a toggle must not do.
            const knob_e = ui.rect(.{
                .width = knob,
                .height = knob,
                .style = .{ .bg = th.bg, .radius = knob * 0.5 },
            });
            knob_e.offset = .{ if (o.checked) w - knob - 2 else 2, 2 };
            break :blk ui.stack(.{ .width = w, .height = o.box, .children = &.{ track, knob_e } });
        },
    };
    const line = ui.row(.{
        .children = &.{ box, ui.text(.{ .label = o.label, .size = o.size }) },
        .gap = o.gap,
        .key = o.key,
        .on_press = o.msg,
        .style = o.style,
        .margin_left = o.margin_left,
        .margin_right = o.margin_right,
        .margin_top = o.margin_top,
        .margin_bottom = o.margin_bottom,
    });
    // Start, not the middle: the box sits on the FIRST LINE's box, so a
    // label that wraps keeps the box beside its opening words instead of
    // drifting to the centre of the paragraph. Set afterwards because
    // `row_align` is a property of the row element, not an option of the
    // container builders.
    line.row_align = .start;
    // A Tab stop, unlike a toast: this is a control the keyboard must
    // be able to reach. `row` has no `focusable` option because a row is
    // a container -- being focusable is the one thing a control asks for
    // that its container kind cannot express.
    line.focusable = true;
    return line;
}

pub fn ToastOpts(comptime M: type) type {
    return struct {
        key: u64,
        text: []const u8,
        severity: elmz.Severity = .info,
        ttl_ms: u32 = 4000,
        /// Emitted on expiry and on a click. The same message both ways on
        /// purpose: "the reader closed it" and "it timed out" are one
        /// decision for the Model, which is to forget it.
        msg: M,
        size: f32 = 13,
        /// Width of the severity bar down the left edge.
        bar_width: f32 = 3,
        style: elmz.Style = .{},
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
    };
}

/// The colour a severity is drawn in. Public because an app composing
/// its own notification -- a banner, a status line -- should not have to
/// repeat the mapping to stay in step with the toast.
/// Names for the three shapes `control` paints. Thin on purpose: the
/// kind is the only thing they decide, so behaviour has one home and
/// cannot drift between a toggle and a checkbox that look different.
pub fn checkbox(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    var c = o;
    c.kind = .checkbox;
    return ui.control(c);
}

pub fn radio(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    var c = o;
    c.kind = .radio;
    return ui.control(c);
}

/// A toggle is a checkbox with different paint: same key, same message,
/// same checked-in / message-out ownership. Only the silhouette moves.
pub fn toggle(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    var c = o;
    c.kind = .toggle;
    return ui.control(c);
}

/// A notification. The Model owns whether it exists; the runtime owns
/// when it stops, because the clock is the one thing `view` cannot see.
///
/// Carries `key` and `on_press` for two separate reasons: a click is how
/// a reader dismisses it early, and the keyed hit region is also how the
/// runtime finds the rect it needs to pause the countdown while the
/// pointer is over it. NOT focusable -- a notification must never take
/// a Tab stop away from the thing underneath.
pub fn toast(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    // Height 0 on purpose. A stretched row paints every child at the
    // row's inner height regardless of what the child measured, so the
    // stripe takes no part in sizing the row (the label does that) and
    // still spans it exactly -- including a label that wraps. Giving it
    // an explicit height would instead make a two-line toast shorter
    // than the label inside it.
    const stripe = ui.rect(.{
        .width = o.bar_width,
        .height = 0,
        .style = .{ .bg = ui.severityColor(o.severity) },
    });
    const e = ui.row(.{
        .children = &.{ stripe, ui.text(.{ .label = o.text, .size = o.size }) },
        .gap = 8,
        .style = .{
            .bg = ui.theme.panel,
            .border = ui.theme.border,
            .radius = 6,
            .pad = 8,
        },
        .margin_left = o.margin_left,
        .margin_right = o.margin_right,
        .margin_top = o.margin_top,
        .margin_bottom = o.margin_bottom,
    });
    // Caller style last, like every other builder, but before the
    // payload: a style that changes the fill must not be able to drop
    // the widget and leave a toast the runtime never expires.
    e.mergeStyle(o.style);
    e.key = o.key;
    e.on_press = o.msg;
    e.widget = ui.payload(.{ .toast = .{
        .severity = o.severity,
        .ttl_ms = o.ttl_ms,
        .msg = o.msg,
    } });
    return e;
}

pub fn Tab(comptime M: type) type {
    return struct {
        label: []const u8,
        /// Dispatched on click, and by Enter or Space when the cursor is on
        /// this tab. A Msg carries no payload, so "which tab" is the
        /// identity of the message rather than a number inside it.
        msg: M,
        /// Painted only while this tab is the selected one. Empty is legal:
        /// a strip governing content the app draws elsewhere is a normal
        /// shape, not a degenerate one.
        children: []const *elmz.Element(M) = &.{},
    };
}

pub fn TabsOpts(comptime M: type) type {
    return struct {
        key: u64,
        /// The Model decides. Out of range paints an empty panel instead of
        /// asserting: a rebuilt view can drop a tab the Model still names,
        /// and a library that panics on that turns a stale index into a
        /// crash on the frame after a content change.
        selected: u16,
        tabs: []const Tab(M),
        size: f32 = 16,
        gap: f32 = 4,
        pad: f32 = 10,
        width: ?f32 = null,
        style: elmz.Style = .{},
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        disabled: bool = false,
    };
}

/// A tab strip over its panels, where only the selected tab's children
/// are in the tree at all -- the others are never built, so nothing
/// hidden can take a focus stop or a hit region.
///
/// Every tab is a ROVING row, exactly as in `ui.list`: the strip is one
/// Tab stop and arrows move between tabs, which is what makes a ten-tab
/// window cost one press of Tab rather than ten.
///
/// The live tab is marked with a `.selected` fill, `.text` in place of
/// `.text_muted`, and an `.accent` border. An UNDERLINE indicator would
/// be the usual shape and is the one thing deliberately not done: a bar
/// spanning the tab needs the tab's own laid-out width, and `view`
/// cannot measure text without becoming a function of the font. The
/// border carries the same signal -- `.selected` and `.hover` are only
/// 1.2:1 apart, so something in the accent colour has to say which is
/// live -- without inventing a second measurement path.
pub fn tabs(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    const Elem = @TypeOf(ui.*).Elem;
    const th = ui.theme;
    const btns = ui.alloc().alloc(*Elem, o.tabs.len) catch {
        ui.failWith(.layout_allocation);
        return ui.column(.{ .children = &.{} });
    };
    for (o.tabs, 0..) |t, i| {
        const live = i == @as(usize, o.selected);
        const label = ui.text(.{
            .label = t.label,
            .size = o.size,
            .style = .{ .fg = if (live) th.text else th.text_muted },
        });
        const b = ui.row(.{
            .children = &.{label},
            .style = .{
                .bg = if (live) th.selected else null,
                .border = if (live) th.accent else null,
                .pad = o.pad,
            },
            .hover_bg = .{ .solid = th.hover },
            .on_press = t.msg,
        });
        b.key = @TypeOf(ui.*).rovingKey(o.key, @intCast(i));
        b.roving = o.key;
        b.roving_index = @intCast(i);
        b.disabled = o.disabled;
        btns[i] = b;
    }
    const panel = if (@as(usize, o.selected) < o.tabs.len)
        ui.column(.{ .children = o.tabs[o.selected].children })
    else
        ui.column(.{ .children = &.{} });
    const strip = ui.row(.{ .children = btns, .gap = o.gap });
    const root = ui.column(.{
        .children = &.{ strip, panel },
        .gap = o.gap,
        .width = o.width,
        .style = o.style,
        .margin_left = o.margin_left,
        .margin_right = o.margin_right,
        .margin_top = o.margin_top,
        .margin_bottom = o.margin_bottom,
        .disabled = o.disabled,
    });
    root.key = o.key;
    root.focusable = true;
    return root;
}

pub fn ListOpts(comptime M: type) type {
    return struct {
        key: u64,
        rows: []const elmz.Choice(M),
        /// The committed row, owned by the Model. PAINTING ONLY: the
        /// cursor is the runtime's, because "where the keyboard was last"
        /// is not data, and restoring it into a different list after a
        /// remount would land on an index that no longer means the same
        /// thing.
        selected: ?u16 = null,
        /// Uniform on purpose. A list whose rows differ in height needs the
        /// cursor position to be computed rather than multiplied, and
        /// nothing has asked for that.
        row_h: f32 = 26,
        size: f32 = 16,
        width: ?f32 = null,
        gap: f32 = 0,
        pad: f32 = 8,
        style: elmz.Style = .{},
        margin_left: f32 = 0,
        margin_right: f32 = 0,
        margin_top: f32 = 0,
        margin_bottom: f32 = 0,
        disabled: bool = false,
    };
}

/// A vertical list as ONE Tab stop, with arrows moving inside it.
///
/// No widget payload, and that is a deliberate reading of the rules
/// rather than an omission: a list is a STRUCTURE, not a control. Every
/// behaviour it needs already exists -- roving is `Element.roving`,
/// selection belongs to the Model, hover and press are ordinary fields
/// on the row -- so a `.list` payload would carry nothing the runtime
/// could act on.
///
/// Rows are `focusable` even though `focusStep` skips them, because a
/// region has to EXIST before `rovingStep` can find it: `hitAppend`
/// records one for a keyed focusable element, which is exactly what
/// makes an arrow able to land on a row that carries no message.
pub fn list(ui: anytype, o: anytype) *@TypeOf(ui.*).Elem {
    const Elem = @TypeOf(ui.*).Elem;
    const th = ui.theme;
    const kids = ui.alloc().alloc(*Elem, o.rows.len) catch {
        ui.failWith(.layout_allocation);
        return ui.column(.{ .children = &.{} });
    };
    for (o.rows, 0..) |r, i| {
        const live = o.selected != null and o.selected.? == @as(u16, @intCast(i));
        const label = ui.text(.{
            .label = r.label,
            .size = o.size,
            .style = .{ .fg = if (live) th.text else th.text_muted },
        });
        const item = ui.row(.{
            .children = &.{label},
            .height = o.row_h,
            .style = .{
                .bg = if (live) th.selected else null,
                .pad = o.pad,
            },
            .hover_bg = .{ .solid = th.hover },
            .on_press = r.msg,
        });
        item.key = @TypeOf(ui.*).rovingKey(o.key, @intCast(i));
        item.focusable = true;
        item.disabled = r.disabled or o.disabled;
        // A disabled row is not a cursor stop: stepping onto something
        // that cannot be activated is a dead end in the middle of a
        // list, and arrows would appear to skip for no reason.
        if (!item.disabled) {
            item.roving = o.key;
            item.roving_index = @intCast(i);
        }
        kids[i] = item;
    }
    const root = ui.column(.{
        .children = kids,
        .gap = o.gap,
        .width = o.width,
        .style = o.style,
        .margin_left = o.margin_left,
        .margin_right = o.margin_right,
        .margin_top = o.margin_top,
        .margin_bottom = o.margin_bottom,
        .disabled = o.disabled,
    });
    root.key = o.key;
    root.focusable = true;
    return root;
}
