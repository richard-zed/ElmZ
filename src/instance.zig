//! One call to stand a program up: canvas, typeface, runtime.
//!
//! Ownership is the point. The canvas BORROWS the font bytes, so the bytes must
//! outlive it; deinit frees in that order and callers cannot get it wrong.

const std = @import("std");
const types = @import("types");
const software = @import("software");

// The runtime lives in elmz.zig, which is this file's parent module, so it
// cannot be imported from here without a cycle. elmz.zig passes these in.
pub const Deps = struct {
    RuntimeFn: fn (type, type) type,
    Action: fn (type) type,
    Ui: fn (type) type,
    Element: fn (type) type,
};

const Allocator = std.mem.Allocator;

pub fn Instance(comptime S: type, comptime M: type, deps: Deps) type {
    return struct {
        const Self = @This();
        pub const RuntimeT = deps.RuntimeFn(S, M);

        gpa: Allocator,
        /// Kept for bufferless writes the caller does not want to thread through.
        io: std.Io,
        canvas: software.Canvas,
        /// Borrowed by the canvas. Freed after it, in deinit.
        font_bytes: ?[]u8,
        rt: RuntimeT,

        pub const Options = struct {
            size: types.Size,
            /// Family name, resolved through the system font dirs. Null keeps
            /// the built-in face.
            font: ?[]const u8 = null,
            initial: S,
            update: *const fn (*S, M) deps.Action(M),
            view: *const fn (*S, *deps.Ui(M)) *deps.Element(M),
        };

        pub fn deinit(self: *Self) void {
            self.canvas.deinit();
            // After the canvas, which holds a slice into these bytes.
            if (self.font_bytes) |fb| self.gpa.free(fb);
        }

        /// Build one frame. The caller owns the result and must deinit it.
        pub fn paint(self: *Self) !RuntimeT.FrameT {
            return self.rt.frame(.{ .w = @floatFromInt(self.canvas.w), .h = @floatFromInt(self.canvas.h) }, self.canvas.renderer());
        }

        /// Draw the frame and, if `name` is given, write it beside the binary.
        pub fn present(self: *Self, f: RuntimeT.FrameT, name: ?[]const u8) !void {
            self.canvas.draw(f);
            if (name) |n| try self.canvas.writePng(self.io, self.gpa, n);
        }
    };
}

pub fn init(
    comptime S: type,
    comptime M: type,
    deps: Deps,
    gpa: Allocator,
    io: std.Io,
    opts: Instance(S, M, deps).Options,
) !Instance(S, M, deps) {
    var canvas = try software.Canvas.initIo(gpa, @intFromFloat(opts.size.w), @intFromFloat(opts.size.h), io);

    var font_bytes: ?[]u8 = null;
    errdefer if (font_bytes) |fb| gpa.free(fb);
    if (opts.font) |fam| {
        font_bytes = software.loadFontByName(gpa, io, fam, &.{}) catch null;
        if (font_bytes) |fb| canvas.setFont(fb);
    }

    const rt = deps.RuntimeFn(S, M).init(gpa, opts.initial, opts.update, opts.view);

    return .{
        .gpa = gpa,
        .io = io,
        .canvas = canvas,
        .font_bytes = font_bytes,
        .rt = rt,
    };
}
