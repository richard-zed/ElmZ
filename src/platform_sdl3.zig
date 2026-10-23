//! SDL3 window backend: window, input, and present. It draws nothing — the
//! pixels it is handed come from `software.zig` — and it exposes no SDL type
//! to anything above it, only an `elmz.Window` vtable.
//!
//! SDL3 picks Wayland or X11 by itself; force it with SDL_VIDEODRIVER=wayland.

const std = @import("std");
const elmz = @import("elmz");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// The keys elmz names, resolved from SCANCODE rather than keycode.
///
/// A scancode is a physical POSITION, so `left` stays left on AZERTY, where
/// the keycode reported for that position is something else. Shortcuts want
/// the opposite -- the label -- which is why `Key` carries both and this
/// function picks the stable one for the names.
fn namedKey(sc: c.SDL_Scancode) ?elmz.Named {
    return switch (sc) {
        c.SDL_SCANCODE_RETURN, c.SDL_SCANCODE_KP_ENTER => .enter,
        c.SDL_SCANCODE_ESCAPE => .escape,
        c.SDL_SCANCODE_TAB => .tab,
        c.SDL_SCANCODE_BACKSPACE => .backspace,
        c.SDL_SCANCODE_DELETE => .delete,
        c.SDL_SCANCODE_LEFT => .left,
        c.SDL_SCANCODE_RIGHT => .right,
        c.SDL_SCANCODE_UP => .up,
        c.SDL_SCANCODE_DOWN => .down,
        c.SDL_SCANCODE_HOME => .home,
        c.SDL_SCANCODE_END => .end,
        c.SDL_SCANCODE_PAGEUP => .page_up,
        c.SDL_SCANCODE_PAGEDOWN => .page_down,
        c.SDL_SCANCODE_F1 => .f1,
        c.SDL_SCANCODE_F2 => .f2,
        c.SDL_SCANCODE_F3 => .f3,
        c.SDL_SCANCODE_F4 => .f4,
        c.SDL_SCANCODE_F5 => .f5,
        c.SDL_SCANCODE_F6 => .f6,
        c.SDL_SCANCODE_F7 => .f7,
        c.SDL_SCANCODE_F8 => .f8,
        c.SDL_SCANCODE_F9 => .f9,
        c.SDL_SCANCODE_F10 => .f10,
        c.SDL_SCANCODE_F11 => .f11,
        c.SDL_SCANCODE_F12 => .f12,
        else => null,
    };
}

/// Widen, never narrow. `SDL_Keycode` is already Uint32 and `SDL_Scancode` is
/// an enum with values like 0x40000050 -- the old `@truncate` to u8 turned the
/// left arrow into 'P', which nothing noticed only because no key was bound.
fn keyEvent(ev: c.SDL_KeyboardEvent) elmz.Key {
    const m: u32 = @as(u32, ev.mod);
    return .{
        .named = namedKey(ev.scancode),
        .code = ev.key,
        // translate-c renders SDL_Scancode as c_uint, not an enum, so this
        // is a plain widening rather than an @intFromEnum.
        .scancode = ev.scancode,
        .mods = .{
            .shift = (m & c.SDL_KMOD_SHIFT) != 0,
            .ctrl = (m & c.SDL_KMOD_CTRL) != 0,
            .alt = (m & c.SDL_KMOD_ALT) != 0,
            .gui = (m & c.SDL_KMOD_GUI) != 0,
        },
        .repeat = ev.repeat,
    };
}

pub const Windows = struct {
    const Self = @This();

    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    w: u32,
    h: u32,
    quit: bool = false,
    /// Only this backend toggles fullscreen, so it owns the flag. Querying
    /// SDL for it instead would mean comparing against a window-flags bit,
    /// and that constant has no compile check in a sandbox without headers.
    fullscreen: bool = false,
    /// Clipboard scratch, inbound. The clipboard text belongs to SDL and must
    /// be freed, while the seam hands out BORROWED bytes that stay valid until
    /// the next call -- so SDL's buffer is copied here and immediately freed
    /// rather than returned and leaked.
    clip_in: [4096]u8 = undefined,
    /// Clipboard scratch, outbound. `SDL_SetClipboardText` takes a C string and
    /// the bytes an app passes come from the frame arena with no terminator, so
    /// they are copied behind a NUL. Truncation is deliberate: a clipboard
    /// write is a courtesy, and refusing the whole thing because it was long
    /// would be the worse failure.
    clip_out: [4097]u8 = undefined,

    /// `title` must be null-terminated.
    pub fn init(title: [:0]const u8, w: u32, h: u32) !Self {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer c.SDL_Quit();

        // SDL3: visible by default — no SDL_WINDOW_SHOWN, no x/y. Resizable,
        // because a window that cannot be resized is not the same thing as one
        // that resizes correctly -- tiling window managers resize regardless,
        // and the code has to cope either way.
        const win = c.SDL_CreateWindow(
            title.ptr,
            @intCast(w),
            @intCast(h),
            c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
            return error.SdlWindow;
        };
        errdefer c.SDL_DestroyWindow(win);

        // Must be started before any SDL_EVENT_TEXT_INPUT arrives: without this
        // call the backend never emits text at all, so a field would receive
        // keys and no characters -- the exact failure that looks like "text
        // input is broken" when the seam was never opened.
        _ = c.SDL_StartTextInput(win);

        // null = let SDL choose (Vulkan/GLES on Wayland); fall back to the
        // software renderer on machines with no usable driver.
        const ren = c.SDL_CreateRenderer(win, null) orelse
            c.SDL_CreateRenderer(win, "software") orelse
            {
                std.log.err("SDL_CreateRenderer: {s}", .{c.SDL_GetError()});
                return error.SdlRenderer;
            };
        errdefer c.SDL_DestroyRenderer(ren);
        _ = c.SDL_SetRenderVSync(ren, 1);

        // software.Canvas stores R,G,B,A bytes. On little-endian,
        // SDL_PIXELFORMAT_RGBA32 == SDL_PIXELFORMAT_ABGR8888, i.e. exactly
        // that byte order. If colours come out swapped, this is the line.
        const tex = c.SDL_CreateTexture(
            ren,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(w),
            @intCast(h),
        ) orelse {
            std.log.err("SDL_CreateTexture: {s}", .{c.SDL_GetError()});
            return error.SdlTexture;
        };

        return .{ .window = win, .renderer = ren, .texture = tex, .w = w, .h = h };
    }

    pub fn deinit(self: *Self) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn asWindow(self: *Self) elmz.Window {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = elmz.Window.VTable{
        .poll = vtPoll,
        .present = vtPresent,
        .size = vtSize,
        .density = vtDensity,
        .clipboard_text = vtClipboardText,
        .set_clipboard = vtSetClipboard,
        .deinit = vtDeinit,
    };

    /// `ELMZ_EVENT_TRACE=1` logs the type of every event that reaches the
    /// backend. Off by default. It exists for "the window will not close",
    /// where the only question worth answering is which event the window
    /// manager actually sends -- blaming it on headers is not an answer.
    fn tracing() bool {
        const raw = std.c.getenv("ELMZ_EVENT_TRACE") orelse return false;
        const v = std.mem.span(raw);
        return v.len != 0 and !std.mem.eql(u8, v, "0");
    }

    fn vtPoll(ptr: *anyopaque, timeout_ms: i32) ?elmz.Event {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.quit) return .quit;

        var ev: c.SDL_Event = undefined;
        if (!c.SDL_WaitEventTimeout(&ev, timeout_ms)) return null;
        if (tracing()) std.log.info("sdl event 0x{x}", .{ev.type});

        switch (ev.type) {
            c.SDL_EVENT_QUIT => {
                self.quit = true;
                return .quit;
            },
            // SDL3 raises this when the window manager asks for the window to
            // close -- the title-bar X. It is NOT SDL_EVENT_QUIT, which only
            // appears if something calls SDL_Quit() or pushes it by hand, so
            // handling QUIET alone leaves the close button doing nothing and
            // SDL3 (unlike SDL2) will not tear the window down for you.
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                self.quit = true;
                return .quit;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (ev.button.button != c.SDL_BUTTON_LEFT) return null;
                return .{ .pointer_down = .{ ev.button.x, ev.button.y } };
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (ev.button.button != c.SDL_BUTTON_LEFT) return null;
                return .{ .pointer_up = .{ ev.button.x, ev.button.y } };
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                return .{ .pointer_move = .{ ev.motion.x, ev.motion.y } };
            },
            // No release is coming in either of these: the gesture is over as
            // far as this window is concerned.
            c.SDL_EVENT_WINDOW_FOCUS_LOST, c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                return .pointer_cancel;
            },
            c.SDL_EVENT_KEY_DOWN => {
                // Escape quits. Both forms are checked: the keycode is what SDL
                // promises, but a report that arrives through a different
                // mapping puts the value in the scancode, and a silent
                // no-match here is indistinguishable from "the window will not
                // close".
                if (ev.key.key == c.SDLK_ESCAPE or ev.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                    self.quit = true;
                    return .quit;
                }
                // Fullscreen is window policy like Escape-quits, not an app
                // concern. The repaint comes from the resize event SDL sends
                // after this, not from here.
                if (ev.key.key == c.SDLK_F11 or ev.key.scancode == c.SDL_SCANCODE_F11) {
                    self.fullscreen = !self.fullscreen;
                    _ = c.SDL_SetWindowFullscreen(self.window, self.fullscreen);
                    return null;
                }
                return .{ .key = keyEvent(ev.key) };
            },
            c.SDL_EVENT_KEY_UP => return .{ .key_up = keyEvent(ev.key) },
            // Typed text, not a keysym: this is the only event that survives a
            // dead key, a compose sequence or an IME commit. `SDL_EVENT_TEXT_EDITING`
            // (pre-edit, underlined composition) is deliberately not forwarded
            // yet -- that is a candidate list, and a field that cannot draw one
            // would be lying about what it supports.
            // Scroll has a TARGET without being a click: the deltas apply to
            // whatever is under the cursor, so the position rides along.
            // UNVERIFIED IN THIS SANDBOX (no SDL headers here) -- the field
            // names are SDL3's documented SDL_MouseWheelEvent.
            c.SDL_EVENT_MOUSE_WHEEL => return .{ .wheel = .{
                .dx = ev.wheel.x,
                .dy = ev.wheel.y,
                .x = ev.wheel.mouse_x,
                .y = ev.wheel.mouse_y,
            } },
            // The window adopted the new size before this arrives, so the
            // runner is free to read it back rather than trust a payload.
            c.SDL_EVENT_WINDOW_RESIZED => return .resize,
            c.SDL_EVENT_TEXT_INPUT => return .{ .text = std.mem.span(ev.text.text) },
            else => return null,
        }
    }

    /// Device pixels per logical unit. SDL reports this as the window's pixel
    /// density, which is what a scaled Wayland output or a Windows display
    /// scale reports -- 1.0 on an unscaled display, so the unscaled path costs
    /// one call and changes nothing.
    fn vtDensity(ptr: *anyopaque) f32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const d = c.SDL_GetWindowPixelDensity(self.window);
        return if (d > 0) d else 1.0;
    }

    fn vtPresent(ptr: *anyopaque, pixels: []const u8, pixel_size: elmz.Size) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // The same rounding the runner uses to size the canvas. These two have
        // to agree to the pixel: the buffer handed in IS the canvas, and this
        // number sizes the texture. Disagree by one and every frame is resampled
        // by a hair -- the sort of softness that gets blamed on HiDPI.
        const tw: u32 = if (pixel_size.w >= 1) @intFromFloat(@ceil(pixel_size.w)) else 1;
        const th: u32 = if (pixel_size.h >= 1) @intFromFloat(@ceil(pixel_size.h)) else 1;
        const needed = @as(usize, tw) * th * 4;
        if (pixels.len < needed) return;

        // A streaming texture is a fixed size, so a resized window needs a new
        // one. Without this the OLD texture is stretched onto the new output,
        // which is why a resized window used to look magnified rather than
        // merely bigger.
        if (tw != self.w or th != self.h) {
            const tex = c.SDL_CreateTexture(
                self.renderer,
                c.SDL_PIXELFORMAT_RGBA32,
                c.SDL_TEXTUREACCESS_STREAMING,
                @intCast(tw),
                @intCast(th),
            ) orelse {
                std.log.err("SDL_CreateTexture (resize): {s}", .{c.SDL_GetError()});
                return;
            };
            c.SDL_DestroyTexture(self.texture);
            self.texture = tex;
            self.w = tw;
            self.h = th;
        }

        _ = c.SDL_UpdateTexture(self.texture, null, pixels.ptr, @intCast(self.w * 4));
        _ = c.SDL_RenderClear(self.renderer);
        // null dstrect = scale to the whole output, which is also what keeps
        // HiDPI from letterboxing. At density 1 that is exact; on a scaled
        // display this upsampled a logical-size buffer, which is the HiDPI
        // step and not this one.
        _ = c.SDL_RenderTexture(self.renderer, self.texture, null, null);
        _ = c.SDL_RenderPresent(self.renderer);
    }

    fn vtSize(ptr: *anyopaque) elmz.Size {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        if (w <= 0 or h <= 0) {
            return .{ .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) };
        }
        return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    fn vtClipboardText(ptr: *anyopaque) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const raw = c.SDL_GetClipboardText();
        if (raw == null) return null;
        defer c.SDL_free(@ptrCast(raw));
        const bytes = std.mem.sliceTo(raw, 0);
        if (bytes.len == 0) return null;
        const n = @min(bytes.len, self.clip_in.len);
        @memcpy(self.clip_in[0..n], bytes[0..n]);
        return self.clip_in[0..n];
    }

    fn vtSetClipboard(ptr: *anyopaque, text: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const n = @min(text.len, self.clip_out.len - 1);
        @memcpy(self.clip_out[0..n], text[0..n]);
        self.clip_out[n] = 0;
        _ = c.SDL_SetClipboardText(@ptrCast(&self.clip_out));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
