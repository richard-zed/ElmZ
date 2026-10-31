//! Software backend for elmz: an RGB framebuffer with a dependency-free PNG
//! encoder, plus `elmfont` -- the built-in 5x6 face used when no real typeface
//! is attached, so a missing font is legible instead of blank. This is the backend you want while you are
//! still arguing with layout; swap in a GPU backend later behind the same
//! `elmz.Renderer` vtable.

const std = @import("std");
const elmz = @import("elmz");
const cedar = @import("cedar.zig");
const gamma = @import("gamma.zig");
const elmfont = @import("elmfont.zig");

/// Cedar is the font backend. One name, because a canvas built against a face
/// the rest of the library does not know is not a configuration anyone wants.
const Face = cedar.Font;
/// A canvas with NO typeface, which is the state an app that names no font is
/// in: text goes through the built-in bitmap face.
fn testCanvas(gpa: Allocator, w: u32, h: u32) !Canvas {
    return Canvas.init(gpa, w, h);
}

/// Attach a real face from this machine, or null. Tests that assert glyph
/// behaviour -- outlines, kerning, cache hits, CJK kinsoku -- cannot run on the
/// bitmap face, and the alternative to borrowing the system's is carrying a
/// typeface in the repo. On a machine with no fonts they skip; the gate then
/// says what it did not check instead of pretending.
fn withFace(c: *Canvas) ?[]u8 {
    return withFaceIf(c, 'H');
}

/// A real face from this machine that maps `cp`, or null. Tests that assert on
/// actual glyphs ask for the character they are about to draw: taking whatever
/// font the directory lists first meant a Noto Arabic subset was handed to a
/// Latin assertion, which fails on valid data and reads like a bug in us.
fn withFaceIf(c: *Canvas, cp: u21) ?[]u8 {
    const all = testing_font.systemFonts(testing.allocator, std.testing.io) orelse return null;
    defer {
        for (all) |q| testing.allocator.free(q);
        testing.allocator.free(all);
    }
    for (all) |bytes| {
        var f = Face.init(bytes);
        if (!f.hasGlyph(cp)) continue;
        // The canvas borrows; give it its own copy so the loop can free the rest.
        const copy = testing.allocator.dupe(u8, bytes) catch return null;
        c.setFont(copy);
        return copy;
    }
    return null;
}

const builtin = @import("builtin");

/// Tests measure and draw with real glyph data, but the library must not embed
/// a face -- so this decl is unreachable outside a test build.
/// Read a font file, trying `path` as given and then the same name beside the
/// executable -- so a binary in `zig-out/bin` finds its font without relying on
/// the working directory. Caller owns the bytes; they must outlive the canvas.
pub fn loadFont(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024))) |b| {
        return b;
    } else |_| {}
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return error.FontNotFound;
    const full = try std.fs.path.join(gpa, &.{ dir, std.fs.path.basename(path) });
    defer gpa.free(full);
    return std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(16 * 1024 * 1024));
}

/// Where a NAMED face is looked for, in order.
///
/// A user font directory is deliberately absent: finding one means reading
/// HOME, which needs environment access this file has no `io`-free way to do.
/// A caller that has one passes it in `extra_dirs`, searched FIRST, so an app
/// can prefer its own shipped directory over the system's.
pub const font_dirs = [_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts", "/system/fonts" };

/// The single face the tests measure, and the only one they look for.
///
/// Not a search: a test that asserts different things on different machines is
/// not much of a test. Absent means the caller skips.
pub const fixture_face: []const u8 = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

fn looksLikePath(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return true;
    inline for ([_][]const u8{ ".ttf", ".otf", ".ttc" }) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn hasFontExt(name: []const u8) bool {
    // ".ttc" included: CJK faces ship as collections and are frequently the
    // ONLY CJK typeface on a stock system. Font.init already handles "ttcf".
    inline for ([_][]const u8{ ".ttf", ".otf", ".ttc" }) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn collectFonts(gpa: Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!hasFontExt(entry.path)) continue;
        const full = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
        errdefer gpa.free(full);
        try out.append(gpa, full);
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Style strings that mean "the plain one".
///
/// A query naming a family and no style must resolve to that family's Regular
/// face. Five DejaVu files share the family name, and `DejaVuSans-Bold.ttf` is
/// a different face -- picking it because it sorted first is a substitution
/// nobody asked for, and it renders perfectly, so nobody would notice.
fn isRegular(style: []const u8) bool {
    if (style.len == 0) return true;
    inline for ([_][]const u8{ "Regular", "Book", "Normal" }) |r| {
        if (eqlIgnoreCase(style, r)) return true;
    }
    return false;
}

const no_match: u8 = 0xff;

/// How well a face answers to `name`, lower being better.
///
/// 0 = this family, plain style; 1 = this family, some other style; 2 = the
/// `"Family Style"` form; `no_match` otherwise. A RANK rather than a yes/no
/// because "the family matches" is not enough to identify a face.
fn faceRank(face: *const Face, name: []const u8) u8 {
    var fam_buf: [128]u8 = undefined;
    var sty_buf: [128]u8 = undefined;
    const fam = face.family(&fam_buf) orelse return no_match;
    if (eqlIgnoreCase(fam, name)) {
        const sty = face.style(&sty_buf) orelse return 1;
        return if (isRegular(sty)) 0 else 1;
    }
    // Split at the LAST space, so a family with spaces of its own still works.
    const cut = std.mem.lastIndexOfScalar(u8, name, ' ') orelse return no_match;
    if (!eqlIgnoreCase(fam, name[0..cut])) return no_match;
    const sty = face.style(&sty_buf) orelse return no_match;
    return if (eqlIgnoreCase(sty, name[cut + 1 ..])) 2 else no_match;
}

/// Best match for `name` among the fonts under `dirs`, or `error.FontNotFound`.
fn searchDirs(gpa: Allocator, io: std.Io, dirs: []const []const u8, name: []const u8) ![]u8 {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    for (dirs) |d| collectFonts(gpa, io, d, &paths) catch {};
    if (paths.items.len == 0) return error.FontNotFound;

    // A walk's order is undefined, so two machines could otherwise pick
    // different faces for one name. Sorting makes the tie-break mean something;
    // rank decides which of the candidates wins.
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var best: ?[]u8 = null;
    var best_rank: u8 = no_match;
    for (paths.items) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch continue;
        // No cache attached on purpose: `family` reads the name table and
        // nothing else, so a search never pays for a glyph cache per candidate.
        const face = Face.init(bytes);
        const rank = faceRank(&face, name);
        if (rank == no_match or rank >= best_rank) {
            gpa.free(bytes);
            continue;
        }
        if (best) |b| gpa.free(b);
        best = bytes;
        best_rank = rank;
        if (rank == 0) break;
    }
    return best orelse error.FontNotFound;
}

/// Resolve a FONT NAME to file bytes.
///
/// Matching happens against the face's own `name` table, never the filename: a
/// theme naming "Inter" must find `Inter-Regular.otf`, and must NOT find some
/// other face that merely happens to be called Inter.ttf. That distinction is
/// the entire reason this is not a filename join.
///
/// A name containing a path separator, or ending in `.ttf`/`.otf`/`.ttc`, is
/// taken as a PATH and handed to `loadFont` -- the escape hatch for an app that
/// ships one private face and would rather name the file than the family.
///
/// Returns the bytes of the first match; the caller owns them. Nothing found is
/// `error.FontNotFound`, which the runner bands rather than papering over with a
/// substitute face nobody could see was wrong.
pub fn loadFontByName(gpa: Allocator, io: std.Io, name: []const u8, extra_dirs: []const []const u8) ![]u8 {
    if (looksLikePath(name)) return loadFont(gpa, io, name);

    // Caller-provided directories win outright, the way PATH order works: an app
    // that ships a face gets it even when the system has the same family.
    if (searchDirs(gpa, io, extra_dirs, name)) |bytes| {
        return bytes;
    } else |e| switch (e) {
        // The only failure a search can report: an unreadable file is skipped,
        // not fatal, because one broken font in a directory must not hide the
        // good ones next to it.
        error.FontNotFound => {},
    }
    return searchDirs(gpa, io, &font_dirs, name);
}

/// An ABSOLUTE fixture directory.
///
/// `std.testing.tmpDir` hands back a path relative to the process's cwd, and
/// re-resolving it from a different cwd is exactly how a test passes for the
/// wrong reason: the first version of this test "found" the system's own
/// DejaVu after the fixture directory failed to open, and the two files are
/// byte-identical, so nothing distinguished a working search from a broken one.
fn fontFixture(io: std.Io, dir_path: []const u8) !std.Io.Dir {
    std.Io.Dir.deleteDirAbsolute(io, dir_path) catch {};
    try std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir);
    return std.Io.Dir.openDirAbsolute(io, dir_path, .{});
}

fn fontFixtureCleanup(io: std.Io, dir_path: []const u8) void {
    var d = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return;
    d.deleteFile(io, "zzz-not-the-family.ttf") catch {};
    d.deleteFile(io, "present.ttf") catch {};
    d.close(io);
    std.Io.Dir.deleteDirAbsolute(io, dir_path) catch {};
}

test "a font name resolves through the face's own name table" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = "/tmp/elm-font-resolver-test";
    var d = try fontFixture(io, dir_path);
    defer fontFixtureCleanup(io, dir_path);
    // The fixture is a REAL face, borrowed from the system, copied under a name
    // the family is not. Matching the filename instead of the `name` table would
    // pass a test where the two agreed, and this one does not. No system fonts is
    // the sandbox case: nothing to prove, so skip rather than ship a font.
    const any = testing_font.anySystemFont(gpa, io) orelse return;
    defer gpa.free(any);
    var fam_buf: [128]u8 = undefined;
    const fam = Face.init(any).family(&fam_buf) orelse return;
    try d.writeFile(io, .{ .sub_path = "zzz-not-the-family.ttf", .data = any });
    d.close(io);

    const bytes = try loadFontByName(gpa, io, fam, &.{dir_path});
    defer gpa.free(bytes);
    try std.testing.expectEqual(any.len, bytes.len);
}

test "a family with no style resolves to its Regular face, not the first file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Several faces share this family on a stock install and the Bold sorts
    // ahead of the Regular, so a family-only match returns Bold -- which renders
    // perfectly and is not the font anyone asked for. Skipped when the system
    // has no such family: nothing to prove either way.
    const bytes = loadFontByName(gpa, io, "DejaVu Sans", &.{}) catch return;
    defer gpa.free(bytes);
    const face = Face.init(bytes);
    var sty_buf: [128]u8 = undefined;
    const sty = face.style(&sty_buf) orelse return;
    try std.testing.expect(isRegular(sty));
}

test "a name no file carries is an error, never a substitute" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = "/tmp/elm-font-resolver-miss";
    var d = try fontFixture(io, dir_path);
    defer fontFixtureCleanup(io, dir_path);
    const any = testing_font.anySystemFont(gpa, io) orelse return;
    defer gpa.free(any);
    try d.writeFile(io, .{ .sub_path = "zzz-not-the-family.ttf", .data = any });
    d.close(io);

    // A face IS there, just not this one. Returning the one that happened to be
    // lying around is the failure this rule exists to prevent: it renders, and
    // nothing about it looks wrong.
    try std.testing.expectError(error.FontNotFound, loadFontByName(gpa, io, "No Such Family 9000", &.{dir_path}));
}

test "a name that is a path is treated as a path, not a family" {
    // The escape hatch is a naming decision, and that is the part worth pinning:
    // what the resolver does with the string. Reading the file afterwards is
    // `loadFont`, which already has a failure test through `attachFont`.
    try std.testing.expect(looksLikePath("src/font.ttf"));
    try std.testing.expect(looksLikePath("/usr/share/fonts/x/Inter.otf"));
    try std.testing.expect(looksLikePath("Face.TTF"));
    try std.testing.expect(looksLikePath("collection.ttc"));
    // A family name is not a path, even when it ends in letters that look like
    // an extension by accident.
    try std.testing.expect(!looksLikePath("DejaVu Sans"));
    try std.testing.expect(!looksLikePath("Inter"));
    try std.testing.expect(!looksLikePath("Sans Book"));
}

/// What tests measure with: the built-in bitmap face, the same one a canvas
/// with no typeface attached uses. There is no sfnt in the repo, so a test that
/// wants real outlines BORROWS one from the system (`anySystemFont`) and skips
/// when the machine has none.
pub const testing_font = struct {
    pub fn get() @This() {
        return .{};
    }
    pub fn measure(_: @This(), bytes: []const u8, size: f32) elmz.TextMetrics {
        return elmfont.measure(bytes, size);
    }
    pub fn wrapLines(_: @This(), bytes: []const u8, dev: f32, max_w: f32, out: [][]const u8) usize {
        return elmfont.wrap(bytes, dev, max_w, out);
    }

    /// Any real face this machine has. A few tests need an sfnt -- one to rename,
    /// one to count as a second face for cache invalidation -- and the
    /// alternative to borrowing the system's is carrying a font in the repo,
    /// which is a binary asset with a licence attached to buy nothing.
    /// Every readable face on this machine; caller frees each and the slice.
    /// `anySystemFont` returns only the first, which is fine for "is there a
    /// face at all" but wrong for anything that needs a CAPABILITY -- a machine
    /// holding only Noto Arabic/CJK still has fonts and still has no Latin.
    pub fn systemFonts(gpa: Allocator, io: std.Io) ?[][]u8 {
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        for (font_dirs) |d| {
            var paths: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (paths.items) |q| gpa.free(q);
                paths.deinit(gpa);
            }
            collectFonts(gpa, io, d, &paths) catch continue;
            for (paths.items) |q| {
                // 64MB, not 16: a CJK collection is 19-27MB, and the old cap
                // dropped every one of them at `catch continue` without a word.
                // The only faces left mapped neither Latin nor CJK, so every
                // test that draws real glyphs took its `orelse return` and
                // passed having proved nothing.
                const bytes = std.Io.Dir.cwd().readFileAlloc(io, q, gpa, .limited(64 * 1024 * 1024)) catch continue;
                if (bytes.len <= 4) {
                    gpa.free(bytes);
                    continue;
                }
                out.append(gpa, bytes) catch gpa.free(bytes);
            }
        }
        return out.toOwnedSlice(gpa) catch null;
    }

    /// A face that actually maps every one of `cps`, or null.
    ///
    /// `anySystemFont` answers "is there a face at all", which is the wrong
    /// question for a test that measures a specific string: the first face in
    /// directory order on a stock Linux box is Noto Naskh Arabic, which parses
    /// perfectly and has no CJK, so a test asserting on \u65e5 measures zero and
    /// fails for a reason that has nothing to do with the code under test.
    /// Asking the face is the same rule `Font.hasGlyph` exists for.
    pub fn fontWith(gpa: Allocator, io: std.Io, cps: []const u21) ?[]u8 {
        const all = systemFonts(gpa, io) orelse return null;
        var keep: ?[]u8 = null;
        for (all) |bytes| {
            if (keep != null) {
                gpa.free(bytes);
                continue;
            }
            const f = @import("cedar.zig").Font.init(bytes);
            var ok = f.available();
            for (cps) |cp| {
                if (!f.hasGlyph(cp)) ok = false;
            }
            if (ok) keep = bytes else gpa.free(bytes);
        }
        gpa.free(all);
        return keep;
    }

    /// One named fixture face, or null to skip.
    ///
    /// This used to walk `font_dirs` and return the FIRST readable file, which
    /// is whatever the filesystem happens to list first -- on a stock Linux box
    /// that is a Noto Arabic face, which parses fine and draws nothing for
    /// Latin. A caller that then measured a string got a plausible number for a
    /// font it never asked for, which is how a test passes while proving
    /// nothing. Naming one face makes the result the same everywhere, and a
    /// missing face skips instead of silently substituting a different one.
    pub fn anySystemFont(gpa: Allocator, io: std.Io) ?[]u8 {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            fixture_face,
            gpa,
            .limited(16 * 1024 * 1024),
        ) catch return null;
        if (bytes.len <= 4) {
            gpa.free(bytes);
            return null;
        }
        return bytes;
    }
};
const Allocator = std.mem.Allocator;

/// Falloff width at a pixel, given a light direction.
///
/// A rounded rect's outward normal is axis aligned, so the width only needs to
/// know which edge is nearest -- which the half-extent terms already answer. The
/// dot product against the cast direction then says whether this edge faces the
/// light (narrow) or away from it (wide). Guarded by a floor so a grazing light
/// cannot collapse the ramp to nothing.
fn lightWidth(blur: f32, px: f32, py: f32, hx: f32, hy: f32, cast: [2]f32) f32 {
    // Outside-ness per axis, positive outside the half-extent. The GOVERNING axis
    // is the one further out, and the normal points from the centre toward this
    // pixel on that axis. Comparing the abs'd offsets instead gets the mid-edge
    // case exactly backwards: at x = centre the horizontal term is a large negative
    // (deep inside) and would win the comparison, naming a side normal at a pixel
    // that is above the shape.
    const ox = @abs(px) - hx;
    const oy = @abs(py) - hy;
    const x_governs = ox >= oy;
    const nx: f32 = if (x_governs) (if (px < 0) -1 else 1) else 0;
    const ny: f32 = if (x_governs) 0 else (if (py < 0) -1 else 1);
    const f: f32 = std.math.clamp(1.0 + 0.65 * (nx * cast[0] + ny * cast[1]), 0.15, 2.0);
    return blur * f;
}

/// The one ramp, for every mode: coverage is opaque well inside the silhouette,
/// half at the edge, gone well outside. `d` is the signed distance from that
/// silhouette, negative inside. `mode` picks which side survives and, for an
/// inner glow, which DIRECTION the falloff runs.
///
/// Shared by the distance-field path and the stencil bake on purpose. A mode that
/// meant two things depending on which path drew it would be two features wearing
/// one name.
fn ramp(mode: elmz.Halo.Mode, d: f32, blur: f32, core: f32) f32 {
    if (blur <= 0) return 1;
    return switch (mode) {
        // Both halves. `.outer_glow` is the same ramp: what makes it outer is
        // being cut against the ELEMENT's silhouette (see `haloSdf`), not against
        // the shape the ramp was built from. Cutting against the shape leaves a
        // hole exactly where an offset shadow should be visible -- the strip of
        // backdrop between the element's edge and the offset silhouette.
        .glow, .outer_glow => std.math.clamp(0.5 - d / blur, 0, 1),
        // Its own curve, not the shared one mirrored. Mirrored it cannot exceed
        // HALF, because the shared ramp is half-opaque AT the silhouette by
        // construction -- right for a glow straddling an edge, wrong for a rim
        // light that lives entirely inside it. That ceiling, not the falloff, is
        // why the mirrored version read as a smudge.
        //
        // Full at the edge, gone a whole `blur` inward: twice the peak and twice
        // the reach of the mirrored form.
        // Squared, and that is the whole shape of it: drop away fast from the edge,
        // then converge gently instead of arriving.
        //
        // A linear ramp fails both halves. It holds its brightness most of the way
        // in and then terminates, which reads as a band with a hard inner edge --
        // most of the falloff spent where it is invisible, none of it where the eye
        // needs it. `(1-u)^2` is steepest AT the edge (three quarters of the
        // brightness is gone by the halfway point) and flattens as it runs out, so
        // the tail approaches the face colour rather than stopping on it.
        //
        // A soft-at-both-ends curve (`(1-u^2)^2`) was tried and is the wrong way
        // round: peak brightness with zero slope at the boundary is a plateau, not a
        // rim, and the face reads flat.
        // `core` is the flat part of the rim: full brightness for that many pixels
        // before the decay starts. It is subtracted from the depth AFTER the sign
        // test above, because adding it to `d` instead makes the boundary pixel
        // read as "outside" and switches the rim off right where it should be
        // brightest -- which is exactly how the first attempt failed.
        .inner_glow => if (d > 0) 0 else blk: {
            const u = std.math.clamp((-d - core) / blur, 0, 1);
            const left = 1.0 - u;
            break :blk left * left;
        },
    };
}

/// How much a rim light should stop tracing the outline and hug the inscribed
/// ellipse instead.
///
/// Zero for a narrow rim: it is tracing the shape, and the corners are part of
/// what you see. A distance field inverts that as it widens -- inward offsets
/// SHRINK the corner radius (`r - t`), so a glow at half the short side has
/// driven the corners to zero and what it draws is a rectangle of sharp
/// corners, not a softened button. Past that point the outline is not
/// legible anyway: the band from each edge has met in the middle, and the only
/// remaining question is whether the light looks like the shape or like a pool
/// of it. This says "like a pool", from half the short side upward.
fn circularity(w: f32, h: f32, blur: f32) f32 {
    const short = @min(w, h);
    if (short <= 0 or blur <= 0) return 0;
    return std.math.clamp(blur / (short * 0.5) - 0.5, 0, 1);
}

/// Nearest aspect ratio from a short ladder, used to size an inner rim's
/// template.
///
/// The template has to be wider than the corner bands so its centre column is
/// already past the x-independent boundary, but no wider than it needs to be:
/// the pool is baked from the template's OWN dimensions, so a template squarer
/// than its target puts the inscribed ellipse in the wrong place and dims the
/// top and bottom boundary rows. Rounding the aspect to a rung keeps that error
/// to a few percent while still letting one entry serve a range of widths.
fn aspectBucket(a: f32) f32 {
    const rungs = [_]f32{ 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32 };
    if (!(a > 0)) return 1;
    var best = rungs[0];
    var bd = @abs(a - best);
    for (rungs[1..]) |r| {
        const d = @abs(a - r);
        if (d < bd) {
            bd = d;
            best = r;
        }
    }
    return best;
}

/// Distance to an ellipse, to first order.
///
/// The normalised radius says how far out you are and its gradient says how
/// fast that changes, so dividing one by the other converts to pixels. Exact on
/// both axes, and within a pixel of the true distance at the 45 degree corner
/// (14.1 vs ~12.6 on an 80x60 box) -- which is ample for a soft ramp.
fn ellipseDistance(px: f32, py: f32, a: f32, b: f32) f32 {
    const ia = if (a > 0) 1.0 / a else 0;
    const ib = if (b > 0) 1.0 / b else 0;
    const gx = px * ia;
    const gy = py * ib;
    const g = @sqrt(gx * gx + gy * gy);
    if (g <= 0) return -@min(a, b);
    const grad = @sqrt(gx * gx * ia * ia + gy * gy * ib * ib) / g;
    if (grad <= 0) return -@min(a, b);
    return (g - 1) / grad;
}

/// How far a ramp reaches from the silhouette, in pixels, WITHOUT the extra
/// pixel that covers the antialiased edge.
///
/// The shared ramp dies `blur / 2` either side of the edge; a lit one reaches
/// `blur` on the side it is thrown toward; an inner glow dies a full `blur` in.
/// Every walk band and every mask is sized from this, because a band narrower
/// than the ramp silently clips its own falloff -- which is exactly what a
/// longer inner ramp would do at the old `blur / 2`.
fn falloffReach(mode: elmz.Halo.Mode, blur: f32, lit: bool) f32 {
    if (mode == .inner_glow) return blur;
    return blur * (if (lit) @as(f32, 1.0) else 0.5);
}

/// One separable box pass over an RGBA buffer, in place. `rad` is the half-width
/// in pixels and sampling clamps at the edges, so a blur never pulls colour from
/// outside the region it was handed.
///
/// Integer sums and a sliding window: one add and one subtract per pixel per
/// channel rather than `2 * rad + 1` of them, which is what keeps three passes
/// affordable on a whole card. `scratch` is `max(w, h) * 4` bytes, reused by
/// every pass.
fn boxBlur(buf: []u8, w: usize, h: usize, rad: usize, horizontal: bool, scratch: []u8) void {
    const lines = if (horizontal) h else w;
    const len = if (horizontal) w else h;
    if (rad == 0 or len == 0 or lines == 0) return;
    const step: usize = if (horizontal) 4 else w * 4;
    const win: u32 = @intCast(2 * rad + 1);
    const n_i: isize = @intCast(len);
    const rad_i: isize = @intCast(rad);

    var l: usize = 0;
    while (l < lines) : (l += 1) {
        const base = if (horizontal) l * w * 4 else l * 4;
        var sum = [4]u32{ 0, 0, 0, 0 };
        var k: isize = -rad_i;
        while (k <= rad_i) : (k += 1) {
            const ci: usize = @intCast(std.math.clamp(k, 0, n_i - 1));
            const o = base + ci * step;
            sum[0] += buf[o];
            sum[1] += buf[o + 1];
            sum[2] += buf[o + 2];
            sum[3] += buf[o + 3];
        }
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const so = i * 4;
            scratch[so] = @intCast(sum[0] / win);
            scratch[so + 1] = @intCast(sum[1] / win);
            scratch[so + 2] = @intCast(sum[2] / win);
            scratch[so + 3] = @intCast(sum[3] / win);
            const i_i: isize = @intCast(i);
            const rem: usize = @intCast(std.math.clamp(i_i - rad_i, 0, n_i - 1));
            const add: usize = @intCast(std.math.clamp(i_i + rad_i + 1, 0, n_i - 1));
            const ro = base + rem * step;
            const ao = base + add * step;
            sum[0] = sum[0] - buf[ro] + buf[ao];
            sum[1] = sum[1] - buf[ro + 1] + buf[ao + 1];
            sum[2] = sum[2] - buf[ro + 2] + buf[ao + 2];
            sum[3] = sum[3] - buf[ro + 3] + buf[ao + 3];
        }
        // Written back after the whole line is read, because the sliding window
        // reads the pixel it is about to replace.
        i = 0;
        while (i < len) : (i += 1) {
            const o = base + i * step;
            const so = i * 4;
            buf[o] = scratch[so];
            buf[o + 1] = scratch[so + 1];
            buf[o + 2] = scratch[so + 2];
            buf[o + 3] = scratch[so + 3];
        }
    }
}

/// Glyph-cache storage. Owned by the CANVAS, not by the font: the cache keeps
/// slices into these bytes, so a font that carried its own arena would be left
/// pointing at a temporary the first time the value was returned or copied.
const FontMem = struct {
    bytes: [Face.cache_bytes]u8 align(8),
    /// Resolved codepoint -> (glyph, advance),  stored beside the mask cache for
    /// the same reason: both must outlive the value copies a `Face` goes
    /// through, so neither can be a field of the face itself.
    lookup: [Face.lookup_bytes]u8 align(8),
    /// The resolved kern lookups and the slot the face points at. Beside the
    /// other two caches because it obeys the same lifetime rule.
    kern: cedar.Kern = undefined,
    kern_mem: [Face.kern_bytes]u8 align(8),
};

/// One edge crossing a scanline. `dir` carries the edge's direction so a
/// nonzero fill can accumulate winding; an even-odd fill ignores it and pairs
/// the crossings off in order.
const Cross = struct {
    x: f32,
    dir: i8,

    fn lessThan(_: void, a: Cross, b: Cross) bool {
        return a.x < b.x;
    }
};

pub const Canvas = struct {
    const Self = @This();

    gpa: Allocator,
    w: u32,
    h: u32,
    px: []u8, // RGBA8

    /// A baked halo is a stencil: coverage per pixel for one silhouette, tinted
    /// at blit. Keyed on geometry only, so changing a halo's colour never
    /// invalidates it -- which is the entire reason to bake rather than ramp
    /// the distance field every frame.
    masks: std.ArrayListUnmanaged(Mask) = .empty,

    /// Flattened outline for the current path call, and the crossings for one
    /// scanline. Reused rather than allocated per call: a path is a paint-time
    /// shape and the paint path is not allowed to grow the heap every frame.
    poly: std.ArrayListUnmanaged([2]f32) = .empty,
    /// Where each SUBPATH starts inside `poly`. A fill closes a subpath back to
    /// its own first point; without these the filler joined one subpath's last
    /// point to the next one's first, drawing an edge nobody asked for.
    sub_starts: std.ArrayListUnmanaged(usize) = .empty,
    pending_break: bool = false,
    xs: std.ArrayListUnmanaged(Cross) = .empty,

    /// Per-pixel coverage for one row, so overlapping spans of the same
    /// outline accumulate into ONE blend instead of compositing over each
    /// other. Without it a self-overlapping path is darker where it folds.
    cover: []f32 = &.{},

    /// How many stencils have been BAKED, as opposed to found in the cache.
    /// Nothing in the renderer reads this -- it exists so a benchmark can tell
    /// a cache hit from a re-bake. A cache hit is not evidence about dispatch,
    /// and neither is a timing.
    bakes: usize = 0,

    /// The face this canvas measures and draws with. `Font.none` means no
    /// glyph data: text measures at zero and draws nothing. The caller supplies
    /// the bytes -- the library ships no typeface.
    font: Face = .none,

    /// Scratch for the glyph cache, allocated once and reused across faces.
    font_mem: ?*FontMem = null,

    /// Measured strings, keyed on the BYTES THEMSELVES and not a hash of them.
    /// A 64-bit collision would hand back the width of a different string, and
    /// a wrong width is a layout bug that presents as a rendering bug. The
    /// price is one copy per distinct string, bounded by `measure_cap`.
    ///
    /// Keyed on the DEVICE size, so a density change is a MISS rather than a
    /// stale answer -- the same reasoning as the halo stencil's key.
    measure_cache: std.HashMapUnmanaged(MeasureKey, elmz.TextMetrics, MeasureCtx, 80) = .empty,
    /// Hit and miss counts. Nothing in the renderer reads them: they exist so a
    /// benchmark and a test can tell a cached answer from a computed one.
    measure_hits: usize = 0,
    measure_misses: usize = 0,

    /// Line breaks for one (string, size, width), keyed and owned exactly like
    /// `measure_cache`. What a wrap produces is a set of SLICES into the
    /// caller's bytes, plus a pointer into the caller's `out` array, so nothing
    /// it returns can be stored: the entry keeps break OFFSETS and rebuilds the
    /// slices on a hit. Caching the slices would mean holding a pointer into a
    /// frame that has since been reset.
    wrap_cache: std.HashMapUnmanaged(WrapKey, WrapEntry, WrapCtx, 80) = .empty,
    wrap_hits: usize = 0,
    wrap_misses: usize = 0,

    /// Device pixels per logical unit -- the HiDPI density.
    ///
    /// Everything above the renderer works in LOGICAL units: layout, hit rects,
    /// the pointer, every number an app writes. This is the SINGLE place that
    /// converts any of it to pixels. At 1.0 every multiply is exact and the
    /// output is bit-identical to what it was before the field existed, which
    /// is what makes the pins the proof that density changed nothing at 1x.
    ///
    /// Applying it here rather than in layout is deliberate: SDL reports pointer
    /// coordinates in logical units, so conversion at the edge would mean
    /// converting them back, and a density change while a press is in flight
    /// (dragging a window between monitors) would otherwise move the rects out
    /// from under the claim.
    scale: f32 = 1.0,

    const Mask = struct {
        /// Shape size this stencil was baked at. `sw == 0` marks a SLICE
        /// TEMPLATE, which stands in for every size at its radius and blur.
        sw: i32,
        sh: i32,
        r: f32,
        blur: f32,
        /// Which side of the silhouette this stencil carries. Part of the key,
        /// because the same geometry bakes to three different pictures.
        mode: elmz.Halo.Mode = .glow,
        /// Template only: width of the corner band, in pixels.
        corner: u32 = 0,
        /// Tiled entry: `sh` is a REAL height, `rw` spans only the corner band
        /// plus one centre column, and the blit repeats that column across the
        /// target. Used where the field stops varying along x but not along y --
        /// an inner rim on a face shorter than its own falloff. Part of the key
        /// via `core`, because the flat core is baked into the ramp.
        tiled: bool = false,
        /// Flat-core depth this entry was baked with (inner rims only).
        core: f32 = 0,
        rw: u32,
        rh: u32,
        px: []u8 = &.{}, // coverage, one byte per pixel; set by `admit`
    };

    /// Distinct strings held before the cache empties itself. A screen holds a
    /// few hundred labels; a counter that formats a fresh string every frame
    /// would otherwise grow it without bound. The cap is a hard reset rather
    /// than an LRU: resetting is cheap, correct, and needs no clock.
    const measure_cap = 8192;

    /// Distinct strings held before the wrap cache empties itself.
    const wrap_cap = 2048;

    /// `face` is the typeface's fingerprint, and it is in the key because
    /// `font` is a PUBLIC field: `setFont` clears both caches, but nothing
    /// stops a caller assigning a face directly, and without the fingerprint
    /// the old face's widths would answer for the new glyphs -- a layout bug
    /// that presents as a rendering bug, which is the worst kind to chase.
    const MeasureKey = struct { text: []const u8, dev: f32, face: usize };
    const MeasureCtx = struct {
        pub fn hash(_: MeasureCtx, k: MeasureKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&k.dev));
            h.update(std.mem.asBytes(&k.face));
            h.update(k.text);
            return h.final();
        }
        pub fn eql(_: MeasureCtx, a: MeasureKey, b: MeasureKey) bool {
            return a.dev == b.dev and a.face == b.face and std.mem.eql(u8, a.text, b.text);
        }
    };

    const WrapKey = struct { text: []const u8, dev: f32, max_w: f32, face: usize };
    /// `offsets` holds start/end PAIRS, so its length is `2 * n`.
    const WrapEntry = struct { offsets: []u32, n: usize };
    const WrapCtx = struct {
        pub fn hash(_: WrapCtx, k: WrapKey) u64 {
            var h = std.hash.Wyhash.init(1);
            h.update(std.mem.asBytes(&k.dev));
            h.update(std.mem.asBytes(&k.max_w));
            h.update(std.mem.asBytes(&k.face));
            h.update(k.text);
            return h.final();
        }
        pub fn eql(_: WrapCtx, a: WrapKey, b: WrapKey) bool {
            return a.dev == b.dev and a.max_w == b.max_w and a.face == b.face and
                std.mem.eql(u8, a.text, b.text);
        }
    };

    /// Point the canvas at a face. `bytes` must outlive the canvas.
    ///
    /// A different face answers every measurement differently, so both caches
    /// go with it. Cleared unconditionally: emptying an empty map is free, and
    /// the flag that used to guard it was a field doing the same work.
    pub fn setFont(self: *Self, bytes: []const u8) void {
        self.setFontAt(bytes, 0, &.{});
    }

    /// Point the canvas at a VARIABLE INSTANCE of a face.
    ///
    /// `coords` is in axis order, in user units -- a `wght` of 700, not a
    /// normalised value. Empty coords means the face's default instance, which
    /// is exactly what `setFont` asks for.
    ///
    /// Both caches are cleared, and that is not caution: a measurement at 300
    /// is not the measurement at 900, and the cache key carries the INSTANCE,
    /// not the byte buffer, precisely so the two cannot collide. A caller who
    /// varied the weight mid-run without this would lay out the previous
    /// weight's widths.
    ///
    /// The instance borrows `bytes` like every other face here: the same rule
    /// applies, `bytes` must outlive the canvas.
    pub fn setFontAt(self: *Self, bytes: []const u8, index: u32, coords: []const f32) void {
        self.clearMeasureCache();
        self.clearWrapCache();
        var face = Face.initIndex(bytes, index);
        if (coords.len > 0) face = face.atCoords(coords);
        self.font = face;
        if (self.font_mem) |m| {
            self.font.attachCache(&m.bytes);
            self.font.attachLookup(&m.lookup);
            self.font.attachKern(&m.kern, &m.kern_mem);
        }
    }

    pub fn init(gpa: Allocator, w: u32, h: u32) !Self {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        const mem = try gpa.create(FontMem);
        return .{ .gpa = gpa, .w = w, .h = h, .px = px, .font_mem = mem };
    }

    /// Re-point the pixel buffer at `w` x `h`. The masks and the font survive:
    /// a stencil is keyed on the SHAPE it covers, not on the canvas it lands in,
    /// so a window resize invalidates none of them.
    ///
    /// A zero dimension is IGNORED rather than honoured. A minimised window
    /// reports 0x0, and allocating nothing there would mean the next present
    /// hands the backend an empty slice -- the window keeps its last frame
    /// instead, which is what the compositor is already showing.
    pub fn resize(self: *Self, w: u32, h: u32) !void {
        if (w == 0 or h == 0) return;
        if (w == self.w and h == self.h) return;
        const px = try self.gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        self.gpa.free(self.px);
        self.px = px;
        self.w = w;
        self.h = h;
    }

    pub fn deinit(self: *Self) void {
        for (self.masks.items) |m| self.gpa.free(m.px);
        self.masks.deinit(self.gpa);
        self.poly.deinit(self.gpa);
        self.sub_starts.deinit(self.gpa);
        self.xs.deinit(self.gpa);
        if (self.cover.len > 0) self.gpa.free(self.cover);
        self.clearMeasureCache();
        self.measure_cache.deinit(self.gpa);
        self.clearWrapCache();
        self.wrap_cache.deinit(self.gpa);
        if (self.font_mem) |m| self.gpa.destroy(m);
        self.gpa.free(self.px);
    }

    pub fn clear(self: *Self, color: elmz.Color) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            self.px[i + 0] = color.r;
            self.px[i + 1] = color.g;
            self.px[i + 2] = color.b;
            self.px[i + 3] = 255;
        }
    }

    /// Logical rect -> device rect. Returns the input unchanged at 1.0 rather
    /// than multiplying by one, so the common case cannot accumulate so much as
    /// an extra rounding step.
    fn scaledRect(self: *const Self, r: elmz.Rect) elmz.Rect {
        if (self.scale == 1.0) return r;
        return .{
            .x = r.x * self.scale,
            .y = r.y * self.scale,
            .w = r.w * self.scale,
            .h = r.h * self.scale,
        };
    }

    fn blendPixel(self: *Self, x: i64, y: i64, color: elmz.Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.w or uy >= self.h) return;
        const i = (@as(usize, uy) * self.w + ux) * 4;
        // Opaque is not a special case for correctness -- src-over with a=255
        // is an identity -- it is a special case for TIME: it is what nearly
        // every pixel in a UI does, and discovering the identity costs four
        // float conversions and a divide per pixel.
        if (color.a == 255) {
            self.px[i + 0] = color.r;
            self.px[i + 1] = color.g;
            self.px[i + 2] = color.b;
            // Alpha is written here too, and it is not decoration: src-over onto
            // a cleared canvas leaves the destination at 0 when the source only
            // covers it partly, so an entire frame painted with opaque colours
            // would export as a fully TRANSPARENT PNG -- correct RGB, invisible
            // everywhere except a test that compares channels.
            self.px[i + 3] = 255;
            return;
        }
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        self.px[i + 0] = gamma.blend(self.px[i + 0], color.r, a);
        self.px[i + 1] = gamma.blend(self.px[i + 1], color.g, a);
        self.px[i + 2] = gamma.blend(self.px[i + 2], color.b, a);
        // Same rule as `blendCoverage`: src-over on the alpha channel, skipped
        // when the destination is already opaque.
        if (self.px[i + 3] != 255) {
            const da = @as(f32, @floatFromInt(self.px[i + 3])) / 255.0;
            const out = a + da * (1.0 - a);
            self.px[i + 3] = @intFromFloat(@round(out * 255.0));
        }
    }

    /// One scanline in one colour. The blend coefficients are hoisted out of
    /// the loop, which is the whole point of a row fill: the source colour is
    /// constant along the row, so converting it to float 640 times was 640
    /// times too many.
    fn fillRow(self: *Self, x0: i64, x1: i64, y: u32, color: elmz.Color) void {
        if (color.a == 0) return;
        const row = @as(usize, y) * self.w;
        var x: usize = @intCast(x0);
        const end: usize = @intCast(x1);
        if (color.a == 255) {
            while (x < end) : (x += 1) {
                const i = (row + x) * 4;
                self.px[i + 0] = color.r;
                self.px[i + 1] = color.g;
                self.px[i + 2] = color.b;
                self.px[i + 3] = 255;
            }
            return;
        }
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        const inv = 1.0 - a;
        const sr = @as(f32, @floatFromInt(color.r)) * a;
        const sg = @as(f32, @floatFromInt(color.g)) * a;
        const sb = @as(f32, @floatFromInt(color.b)) * a;
        while (x < end) : (x += 1) {
            const i = (row + x) * 4;
            self.px[i + 0] = @intFromFloat(sr + @as(f32, @floatFromInt(self.px[i + 0])) * inv);
            self.px[i + 1] = @intFromFloat(sg + @as(f32, @floatFromInt(self.px[i + 1])) * inv);
            self.px[i + 2] = @intFromFloat(sb + @as(f32, @floatFromInt(self.px[i + 2])) * inv);
        }
    }

    const Span = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

    /// Integer pixel span of `rect` after clipping, or null when nothing is
    /// left. Both bounds are resolved before the loop, so the per-pixel path
    /// is exactly what it was when nothing clips.
    fn clipSpan(self: *Self, rect: elmz.Rect, clip: elmz.Rect) ?Span {
        // Non-finite geometry is refused here, BEFORE the max/min below. Those
        // follow fmax/fmin and silently DROP a NaN, so a NaN coordinate became
        // the clip's own edge and the span covered every pixel the clip allowed
        // -- a broken element painting the whole screen instead of vanishing.
        // Infinity is refused for a second reason: `@intFromFloat` traps on it,
        // and the clamp below runs after the conversion, so it cannot save it.
        if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
            !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or
            !std.math.isFinite(clip.x) or !std.math.isFinite(clip.y) or
            !std.math.isFinite(clip.w) or !std.math.isFinite(clip.h))
            return null;
        // Edges are taken straight from the two rects rather than from
        // `intersect`, whose width is `x1 - x0`. That subtraction is not
        // always exact in f32, and re-deriving `x1` from it could move an
        // edge by one pixel. Copied this way, an unbounded clip reproduces
        // the unclipped arithmetic bit for bit.
        const cx0 = @max(rect.x, clip.x);
        const cy0 = @max(rect.y, clip.y);
        const cx1 = @min(rect.x + rect.w, clip.x + clip.w);
        const cy1 = @min(rect.y + rect.h, clip.y + clip.h);
        if (!(cx1 > cx0 and cy1 > cy0)) return null;
        const w_i: i64 = @intCast(self.w);
        const h_i: i64 = @intCast(self.h);
        const x0 = std.math.clamp(@as(i64, @intFromFloat(@floor(cx0))), 0, w_i);
        const y0 = std.math.clamp(@as(i64, @intFromFloat(@floor(cy0))), 0, h_i);
        const x1 = std.math.clamp(@as(i64, @intFromFloat(@ceil(cx1))), 0, w_i);
        const y1 = std.math.clamp(@as(i64, @intFromFloat(@ceil(cy1))), 0, h_i);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    pub fn fillRect(self: *Self, rect: elmz.Rect, fill: elmz.Fill) void {
        self.fillRectClip(rect, fill, elmz.Rect.unbounded);
    }

    pub fn fillRectClip(self: *Self, rect: elmz.Rect, fill: elmz.Fill, clip: elmz.Rect) void {
        const sp = self.clipSpan(rect, clip) orelse return;
        switch (fill) {
            // The solid case hoists the colour out of the loop entirely: this
            // is still the path every plain background takes, and it must not
            // pay for gradients existing.
            .solid => |c| {
                var y = sp.y0;
                while (y < sp.y1) : (y += 1) self.fillRow(sp.x0, sp.x1, @intCast(y), c);
            },

            // A linear ramp is AFFINE in x and y, so every geometric term in
            // the projection is constant for the whole fill. Deriving them
            // once -- including the reciprocal of the axis length -- is what
            // separates a 20x fill from a 1x one. The old path rebuilt the
            // axis, the length and the whole projection on every pixel.
            .linear => |g| {
                const ax = rect.x + g.from[0] * rect.w;
                const ay = rect.y + g.from[1] * rect.h;
                const dx = (rect.x + g.to[0] * rect.w) - ax;
                const dy = (rect.y + g.to[1] * rect.h) - ay;
                const len2 = dx * dx + dy * dy;
                if (!(len2 > 0)) {
                    const c = g.stops.at(0);
                    var y = sp.y0;
                    while (y < sp.y1) : (y += 1) self.fillRow(sp.x0, sp.x1, @intCast(y), c);
                    return;
                }
                const inv = 1.0 / len2;
                const step = dx * inv; // dt per pixel along x
                const xm = @as(f32, @floatFromInt(sp.x0)) + 0.5;
                var y = sp.y0;
                if (dy == 0) {
                    // Horizontal: the colour depends on x ONLY, so the row of
                    // colours is the same on every scanline. Build it once per
                    // band of columns and replay it -- the ramp becomes a row
                    // fill, which is what makes it cost the same as a solid.
                    const band: i64 = 512;
                    var xs = sp.x0;
                    while (xs < sp.x1) {
                        const xe = @min(sp.x1, xs + band);
                        const n: usize = @intCast(xe - xs);
                        var lut: [512]elmz.Color = undefined;
                        var tt = ((@as(f32, @floatFromInt(xs)) + 0.5 - ax) * dx) * inv;
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            lut[i] = g.stops.atFast(tt);
                            tt += step;
                        }
                        var yy = sp.y0;
                        while (yy < sp.y1) : (yy += 1) {
                            const row = (@as(usize, @intCast(yy)) * self.w + @as(usize, @intCast(xs))) * 4;
                            var j: usize = 0;
                            var off = row;
                            while (j < n) : (j += 1) {
                                const c = lut[j];
                                if (c.a == 255) {
                                    self.px[off + 0] = c.r;
                                    self.px[off + 1] = c.g;
                                    self.px[off + 2] = c.b;
                                    self.px[off + 3] = 255;
                                } else {
                                    self.blendPixel(xs + @as(i64, @intCast(j)), yy, c);
                                }
                                off += 4;
                            }
                        }
                        xs = xe;
                    }
                    return;
                }
                if (dx == 0) {
                    // Constant along the scanline, so it is sampled once per
                    // ROW and the row fill does the rest. This is the case that
                    // made vertical gradients free and horizontal ones 20x.
                    while (y < sp.y1) : (y += 1) {
                        const ym = @as(f32, @floatFromInt(y)) + 0.5;
                        const t = ((xm - ax) * dx + (ym - ay) * dy) * inv;
                        self.fillRow(sp.x0, sp.x1, @intCast(y), g.stops.atFast(t));
                    }
                    return;
                }
                if (twoOpaque(g.stops)) {
                    const ca = g.stops.colors[0];
                    const cb = g.stops.colors[1];
                    while (y < sp.y1) : (y += 1) {
                        const ym = @as(f32, @floatFromInt(y)) + 0.5;
                        const t0 = ((xm - ax) * dx + (ym - ay) * dy) * inv;
                        self.rampRow(sp, y, t0, step, ca, cb);
                    }
                    return;
                }
                while (y < sp.y1) : (y += 1) {
                    const ym = @as(f32, @floatFromInt(y)) + 0.5;
                    // No multiply and no divide inside the row: `t` advances
                    // by a constant. Error over a scanline is under 1e-5,
                    // which is three orders below one unit of 8-bit colour.
                    var t = ((xm - ax) * dx + (ym - ay) * dy) * inv;
                    const row = @as(usize, @intCast(y)) * self.w;
                    var x = sp.x0;
                    var off = (row + @as(usize, @intCast(sp.x0))) * 4;
                    while (x < sp.x1) : (x += 1) {
                        const c = g.stops.atFast(t);
                        if (c.a == 255) {
                            self.px[off + 0] = c.r;
                            self.px[off + 1] = c.g;
                            self.px[off + 2] = c.b;
                            self.px[off + 3] = 255;
                        } else {
                            self.blendPixel(x, y, c);
                        }
                        off += 4;
                        t += step;
                    }
                }
            },

            .radial => |g| {
                const cx = rect.x + g.center[0] * rect.w;
                const cy = rect.y + g.center[1] * rect.h;
                const r = g.radius * rect.w;
                var y = sp.y0;
                if (!(r > 0)) {
                    const c = g.stops.at(1);
                    while (y < sp.y1) : (y += 1) self.fillRow(sp.x0, sp.x1, @intCast(y), c);
                    return;
                }
                // Still a square root per pixel -- that is what a radial ramp
                // is -- but the centre and the reciprocal of the radius are
                // fixed, so only the distance changes.
                // The row split only pays when part of the box lies OUTSIDE
                // the circle. When the circle covers the whole box there is
                // nothing to peel off, and the per-row square root plus the
                // two fillRow calls cost more than the plain loop they
                // replaced -- measured 19.8 -> 24.3 ns/px on a full-page
                // radial, which is a regression, not a fast path.
                const fx0: f32 = @floatFromInt(sp.x0);
                const fx1: f32 = @floatFromInt(sp.x1 - 1);
                const fy0: f32 = @floatFromInt(sp.y0);
                const fy1: f32 = @floatFromInt(sp.y1 - 1);
                const dxm = @max(@abs(fx0 + 0.5 - cx), @abs(fx1 + 0.5 - cx));
                const dym = @max(@abs(fy0 + 0.5 - cy), @abs(fy1 + 0.5 - cy));
                const covered = dxm * dxm + dym * dym <= r * r;
                if (twoOpaque(g.stops) and !covered) {
                    // Outside the radius the colour is flat, so a scanline is
                    // split into constant runs and only the span that actually
                    // crosses the circle pays a square root.
                    const edge = g.stops.colors[1];
                    const r2 = r * r;
                    const invr = 1.0 / r;
                    while (y < sp.y1) : (y += 1) {
                        const dyv = (@as(f32, @floatFromInt(y)) + 0.5) - cy;
                        const rem = r2 - dyv * dyv;
                        if (!(rem > 0)) {
                            self.fillRow(sp.x0, sp.x1, @intCast(y), edge);
                            continue;
                        }
                        const half = @sqrt(rem);
                        const xlo_f = cx - half - 0.5;
                        const xhi_f = cx + half - 0.5;
                        var lo: i64 = sp.x0;
                        if (xlo_f > @as(f32, @floatFromInt(sp.x0))) {
                            const fi = @ceil(xlo_f);
                            lo = if (fi >= @as(f32, @floatFromInt(sp.x1))) sp.x1 else @intFromFloat(fi);
                        }
                        var hi: i64 = sp.x1;
                        if (xhi_f < @as(f32, @floatFromInt(sp.x1 - 1))) {
                            const fi = @floor(xhi_f) + 1;
                            hi = if (fi <= @as(f32, @floatFromInt(sp.x0))) sp.x0 else @intFromFloat(fi);
                        }
                        if (hi < lo) hi = lo;
                        self.fillRow(sp.x0, lo, @intCast(y), edge);
                        self.fillRow(hi, sp.x1, @intCast(y), edge);
                        const rw = @as(usize, @intCast(y)) * self.w;
                        var x = lo;
                        var off = (rw + @as(usize, @intCast(lo))) * 4;
                        while (x < hi) : (x += 1) {
                            const dxv = (@as(f32, @floatFromInt(x)) + 0.5) - cx;
                            const c = g.stops.atFast(@sqrt(dxv * dxv + dyv * dyv) * invr);
                            self.px[off + 0] = c.r;
                            self.px[off + 1] = c.g;
                            self.px[off + 2] = c.b;
                            self.px[off + 3] = 255;
                            off += 4;
                        }
                    }
                    return;
                }
                const inv = 1.0 / r;
                while (y < sp.y1) : (y += 1) {
                    const dyv = (@as(f32, @floatFromInt(y)) + 0.5) - cy;
                    const row = @as(usize, @intCast(y)) * self.w;
                    var x = sp.x0;
                    var off = (row + @as(usize, @intCast(sp.x0))) * 4;
                    while (x < sp.x1) : (x += 1) {
                        const dxv = (@as(f32, @floatFromInt(x)) + 0.5) - cx;
                        const c = g.stops.atFast(@sqrt(dxv * dxv + dyv * dyv) * inv);
                        if (c.a == 255) {
                            self.px[off + 0] = c.r;
                            self.px[off + 1] = c.g;
                            self.px[off + 2] = c.b;
                            self.px[off + 3] = 255;
                        } else {
                            self.blendPixel(x, y, c);
                        }
                        off += 4;
                    }
                }
            },
        }
    }

    /// True when a gradient is the shape almost every UI gradient is: exactly
    /// two stops, pinned at the two ends, both fully opaque. Only then is the
    /// colour a plain affine lerp with no premultiply and no stop search.
    fn twoOpaque(s: elmz.Stops) bool {
        return s.n == 2 and s.colors[0].a == 255 and s.colors[1].a == 255;
    }

    /// One scanline of a two-opaque-stop ramp starting at `t0` and advancing by
    /// `step` per pixel.
    ///
    /// Split into three runs. Below the first stop the colour is flat, above
    /// the second it is flat, and only the middle span carries a gradient -- so
    /// a diagonal fill no longer lerps every pixel of the box, and the flat
    /// runs reuse the solid row writer. In the middle the three channels
    /// advance by addition instead of being re-lerped from `t` per pixel.
    fn rampRow(self: *Self, sp: Span, y: i64, t0: f32, step: f32, a: elmz.Color, b: elmz.Color) void {
        const n: i64 = sp.x1 - sp.x0;
        if (n <= 0) return;
        if (!(step > 0 or step < 0)) {
            self.fillRow(sp.x0, sp.x1, @intCast(y), elmz.Stops.two(a, b).atFast(t0));
            return;
        }
        const nf: f32 = @floatFromInt(n);
        var lead: i64 = 0;
        var ramp_end: i64 = n;
        const lead_color = if (step > 0) a else b;
        const trail_color = if (step > 0) b else a;
        if (step > 0) {
            if (t0 < 0) {
                const fi = @ceil(-t0 / step);
                lead = if (fi >= nf) n else @intFromFloat(fi);
            }
            if (t0 > 1) {
                ramp_end = 0;
            } else {
                const fi = @floor((1.0 - t0) / step) + 1;
                ramp_end = if (fi >= nf) n else @intFromFloat(fi);
            }
        } else {
            if (t0 > 1) {
                const fi = @ceil((t0 - 1.0) / -step);
                lead = if (fi >= nf) n else @intFromFloat(fi);
            }
            if (t0 < 0) {
                ramp_end = 0;
            } else {
                const fi = @floor(t0 / -step) + 1;
                ramp_end = if (fi >= nf) n else @intFromFloat(fi);
            }
        }
        if (ramp_end < lead) ramp_end = lead;
        self.fillRow(sp.x0, sp.x0 + lead, @intCast(y), lead_color);
        self.fillRow(sp.x0 + ramp_end, sp.x1, @intCast(y), trail_color);
        if (ramp_end <= lead) return;
        const t_s = t0 + @as(f32, @floatFromInt(lead)) * step;
        const af: [3]f32 = .{ @floatFromInt(a.r), @floatFromInt(a.g), @floatFromInt(a.b) };
        const bf: [3]f32 = .{ @floatFromInt(b.r), @floatFromInt(b.g), @floatFromInt(b.b) };
        const dv: [3]f32 = .{ (bf[0] - af[0]) * step, (bf[1] - af[1]) * step, (bf[2] - af[2]) * step };
        var cv: [3]f32 = .{
            af[0] + (bf[0] - af[0]) * t_s,
            af[1] + (bf[1] - af[1]) * t_s,
            af[2] + (bf[2] - af[2]) * t_s,
        };
        const row = @as(usize, @intCast(y)) * self.w;
        var x: i64 = lead;
        var off = (row + @as(usize, @intCast(sp.x0 + lead))) * 4;
        while (x < ramp_end) : (x += 1) {
            self.px[off + 0] = @intFromFloat(@round(std.math.clamp(cv[0], 0.0, 255.0)));
            self.px[off + 1] = @intFromFloat(@round(std.math.clamp(cv[1], 0.0, 255.0)));
            self.px[off + 2] = @intFromFloat(@round(std.math.clamp(cv[2], 0.0, 255.0)));
            self.px[off + 3] = 255;
            cv[0] += dv[0];
            cv[1] += dv[1];
            cv[2] += dv[2];
            off += 4;
        }
    }

    /// TrueType text, drawn by the same font that measured it.
    pub fn drawText(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8) void {
        self.drawTextClip(x, y, size, fill, bytes, elmz.Rect.unbounded);
    }

    pub fn drawTextClip(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        if (!self.font.available()) return self.drawTextBitmap(x, y, size, fill, bytes, clip);
        self.font.drawText(self.px, self.w, self.h, x, y, size, fill, bytes, clip);
    }

    /// Text in the built-in face, for a canvas with no typeface attached.
    ///
    /// The alternative is not "slightly worse text", it is no text: the band
    /// reporting a missing font is itself drawn with text, so the failure used
    /// to leave a blank window that looked like a broken renderer. Blending
    /// goes through `blendCoverage` like every other glyph, so a gradient fill
    /// and a fractional alpha behave the same here as they do above.
    fn drawTextBitmap(self: *Self, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        const s = elmfont.scaleFor(size);
        const cell: f32 = @floatFromInt(s);
        const solid: ?elmz.Color = switch (fill) {
            .solid => |c| c,
            else => null,
        };
        // Same refusal as `clipSpan`, which this path bypasses: it converts the
        // clip itself instead of asking for a span, so a non-finite pen or clip
        // would trap in `@intFromFloat` rather than being skipped.
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or
            !std.math.isFinite(clip.x) or !std.math.isFinite(clip.y) or
            !std.math.isFinite(clip.w) or !std.math.isFinite(clip.h))
            return;
        var box: elmz.Rect = .{ .x = x, .y = y, .w = 0, .h = 0 };
        if (solid == null) {
            const tm = elmfont.measure(bytes, size);
            box = .{ .x = x, .y = y, .w = tm.width, .h = tm.height };
        }
        const cx0: i64 = @intFromFloat(@floor(clip.x));
        const cy0: i64 = @intFromFloat(@floor(clip.y));
        const cx1: i64 = @intFromFloat(@ceil(clip.x + clip.w));
        const cy1: i64 = @intFromFloat(@ceil(clip.y + clip.h));

        var pen = x;
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = cedar.decode(bytes, &i);
            if (cp != '\n') {
                const rows = elmfont.glyphFor(cp);
                const gx0: i64 = @intFromFloat(@round(pen));
                // The cell origin plus this glyph's drop, in whole cells. Doing
                // it here rather than in the table keeps one glyph shape serving
                // every position, and keeps measurement (which is x-only)
                // untouched.
                const gy_base: i64 = @intFromFloat(@round(y));
                const gy0: i64 = gy_base + @as(i64, @intCast(elmfont.dyOf(cp) * s));
                for (rows, 0..) |row, gy| {
                    var gx: u32 = 0;
                    while (gx < elmfont.glyph_w) : (gx += 1) {
                        const lit = (row >> @intCast(elmfont.glyph_w - 1 - gx)) & 1;
                        if (lit == 0) continue;
                        // One glyph pixel is `s` square: a bitmap stays square
                        // because `scaleFor` returns whole multiples only.
                        var dy: u32 = 0;
                        while (dy < s) : (dy += 1) {
                            const yy = gy0 + @as(i64, @intCast(gy)) * @as(i64, @intCast(s)) + @as(i64, @intCast(dy));
                            if (yy < cy0 or yy >= cy1) continue;
                            var dx: u32 = 0;
                            while (dx < s) : (dx += 1) {
                                const xx = gx0 + @as(i64, @intCast(gx)) * @as(i64, @intCast(s)) + @as(i64, @intCast(dx));
                                if (xx < cx0 or xx >= cx1) continue;
                                if (xx < 0 or yy < 0 or xx >= self.w or yy >= self.h) continue;
                                const cover = solid orelse fill.colorAt(
                                    box,
                                    @as(f32, @floatFromInt(xx)) + 0.5,
                                    @as(f32, @floatFromInt(yy)) + 0.5,
                                );
                                self.blendCoverage(xx, yy, cover, 1.0);
                            }
                        }
                    }
                }
            }
            pen += cell * @as(f32, @floatFromInt(elmfont.advance));
        }
    }

    fn blendCoverage(self: *Self, x: i64, y: i64, color: elmz.Color, cov: f32) void {
        const a = cov * (@as(f32, @floatFromInt(color.a)) / 255.0);
        if (a <= 0) return;
        const i = (@as(usize, @intCast(y)) * self.w + @as(u32, @intCast(x))) * 4;
        // In light, not in bytes. See gamma.zig -- at half coverage the two
        // disagree by 61 code values, and a UI edge is half coverage.
        self.px[i + 0] = gamma.blend(self.px[i + 0], color.r, a);
        self.px[i + 1] = gamma.blend(self.px[i + 1], color.g, a);
        self.px[i + 2] = gamma.blend(self.px[i + 2], color.b, a);
        // Alpha is COMPOSITED here, not stamped. Stamping 255 the way the
        // opaque writers do would be wrong twice over: coverage is fractional by
        // definition, and a canvas may legitimately start transparent (the blit
        // tests build one). Left alone, the destination alpha was simply never
        // updated -- so a rounded rect or a glyph painted onto a cleared canvas
        // carried correct colour at alpha 0, and `encodePng` (colour type 6)
        // wrote it out as a hole. An opaque destination is the common case and
        // needs no arithmetic: 255 over anything is 255.
        if (self.px[i + 3] != 255) {
            const da = @as(f32, @floatFromInt(self.px[i + 3])) / 255.0;
            const out = a + da * (1.0 - a);
            self.px[i + 3] = @intFromFloat(@round(out * 255.0));
        }
    }

    /// Rounded rect by signed distance: the coverage of a pixel is derived
    /// from its distance to the rounded outline, which antialiases the curve
    /// and, with `stroke`, gives a 1px outline that follows it for free.
    pub fn roundRect(self: *Self, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool) void {
        self.roundRectClip(rect, radius, fill, stroke, elmz.Rect.unbounded);
    }

    fn vtPath(ptr: *anyopaque, x: f32, y: f32, p: elmz.Path, fill: elmz.Fill, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.pathClip(x * self.scale, y * self.scale, p, fill, self.scaledRect(clip));
    }

    /// Flatten, then fill. The subdivision step is here and nowhere else: a
    /// curve is cut to roughly one DEVICE pixel, so the tolerance is right at
    /// every scale without the caller knowing what the scale is.
    pub fn pathClip(self: *Self, ox: f32, oy: f32, p: elmz.Path, fill: elmz.Fill, clip: elmz.Rect) void {
        self.poly.clearRetainingCapacity();
        self.sub_starts.clearRetainingCapacity();
        self.pending_break = true;
        var cur: [2]f32 = .{ ox, oy };
        var start: [2]f32 = cur;
        var pi: usize = 0;
        for (p.ops) |op| {
            switch (op) {
                .move => {
                    if (pi >= p.points.len) return;
                    cur = .{ ox + p.points[pi][0] * self.scale, oy + p.points[pi][1] * self.scale };
                    start = cur;
                    self.pending_break = true;
                    pi += 1;
                },
                .line => {
                    if (pi >= p.points.len) return;
                    const e = [2]f32{ ox + p.points[pi][0] * self.scale, oy + p.points[pi][1] * self.scale };
                    if (!self.emit(cur)) return;
                    if (!self.emit(e)) return;
                    cur = e;
                    pi += 1;
                },
                .quad => {
                    if (pi + 1 >= p.points.len) return;
                    const c = [2]f32{ ox + p.points[pi][0] * self.scale, oy + p.points[pi][1] * self.scale };
                    const e = [2]f32{ ox + p.points[pi + 1][0] * self.scale, oy + p.points[pi + 1][1] * self.scale };
                    if (!self.flattenQuad(cur, c, e)) return;
                    cur = e;
                    pi += 2;
                },
                .cubic => {
                    if (pi + 2 >= p.points.len) return;
                    const c1 = [2]f32{ ox + p.points[pi][0] * self.scale, oy + p.points[pi][1] * self.scale };
                    const c2 = [2]f32{ ox + p.points[pi + 1][0] * self.scale, oy + p.points[pi + 1][1] * self.scale };
                    const e = [2]f32{ ox + p.points[pi + 2][0] * self.scale, oy + p.points[pi + 2][1] * self.scale };
                    if (!self.flattenCubic(cur, c1, c2, e)) return;
                    cur = e;
                    pi += 3;
                },
                .close => {
                    if (!self.emit(cur)) return;
                    if (!self.emit(start)) return;
                    cur = start;
                    // SVG/PDF: a command after a `close` starts a NEW subpath at
                    // the same initial point. Recording the break is what keeps
                    // that subpath from being joined onto this one.
                    self.pending_break = true;
                },
            }
        }
        self.fillPolygonClip(self.poly.items, self.sub_starts.items, p.rule, fill, clip);
    }

    /// A tuple allocator failure mid-outline would otherwise paint a shape with
    /// a vertex missing -- wrong in a way that looks like a path bug. Bailing
    /// out of the whole fill is the honest failure.
    /// Append a point, recording where a SUBPATH begins.
    ///
    /// The filler closes each subpath back to its own first point, which is
    /// both what the spec says and the only way to keep subpaths apart. With a
    /// single flat list the edge from one subpath's end to the next one's
    /// start was never drawn but was still filled as though it had been: with
    /// two CLOSED subpaths the join and the modulo wrap coincide, so they
    /// cancelled and everything looked right; with three they form a triangle
    /// and the fill spills across the whole element (see the three-squares
    /// test). Unclosed subpaths broke even with two.
    fn emit(self: *Self, pt: [2]f32) bool {
        if (self.pending_break) {
            self.sub_starts.append(self.gpa, self.poly.items.len) catch return false;
            self.pending_break = false;
        }
        return self.polyAppend(pt);
    }

    fn polyAppend(self: *Self, pt: [2]f32) bool {
        self.poly.append(self.gpa, pt) catch return false;
        return true;
    }

    fn dist(a: [2]f32, b: [2]f32) f32 {
        const dx = a[0] - b[0];
        const dy = a[1] - b[1];
        return @sqrt(dx * dx + dy * dy);
    }

    /// Segments for a control polygon of length `d`, at about one device pixel
    /// per segment. Bounded at both ends: two segments for a nearly straight
    /// curve (a quad with collinear controls still curves), and a hard ceiling
    /// so one pathological control point cannot flatten into thousands.
    fn segsFor(d: f32) usize {
        if (!(d > 0)) return 2;
        const n = std.math.clamp(@ceil(d), 2, 64);
        return @intFromFloat(n);
    }

    fn flattenQuad(self: *Self, p0: [2]f32, c: [2]f32, p1: [2]f32) bool {
        const n = segsFor(dist(p0, c) + dist(c, p1));
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            const x = u * u * p0[0] + 2 * u * t * c[0] + t * t * p1[0];
            const y = u * u * p0[1] + 2 * u * t * c[1] + t * t * p1[1];
            if (!self.emit(.{ x, y })) return false;
        }
        return true;
    }

    fn flattenCubic(self: *Self, p0: [2]f32, c1: [2]f32, c2: [2]f32, p1: [2]f32) bool {
        const n = segsFor(dist(p0, c1) + dist(c1, c2) + dist(c2, p1));
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            const a = u * u * u;
            const b = 3 * u * u * t;
            const cc = 3 * u * t * t;
            const dd = t * t * t;
            const x = a * p0[0] + b * c1[0] + cc * c2[0] + dd * p1[0];
            const y = a * p0[1] + b * c1[1] + cc * c2[1] + dd * p1[1];
            if (!self.emit(.{ x, y })) return false;
        }
        return true;
    }

    /// Each pixel row is sampled four times vertically, and horizontally each
    /// span contributes its exact overlap, so the edge is antialiased in both
    /// axes without supersampling the interior.
    pub fn fillPolygonClip(self: *Self, pts: []const [2]f32, starts: []const usize, rule: elmz.FillRule, fill: elmz.Fill, clip: elmz.Rect) void {
        if (pts.len < 3) return;
        var minx = pts[0][0];
        var maxx = pts[0][0];
        var miny = pts[0][1];
        var maxy = pts[0][1];
        for (pts[1..]) |p| {
            minx = @min(minx, p[0]);
            maxx = @max(maxx, p[0]);
            miny = @min(miny, p[1]);
            maxy = @max(maxy, p[1]);
        }
        const box = elmz.Rect{ .x = minx, .y = miny, .w = maxx - minx, .h = maxy - miny };
        const sp = self.clipSpan(box, clip) orelse return;
        const x0i: i64 = @max(sp.x0, @as(i64, @intFromFloat(@floor(minx))));
        const x1i: i64 = @min(sp.x1, @as(i64, @intFromFloat(@ceil(maxx))));
        if (x1i <= x0i) return;

        const n: usize = @intCast(x1i - x0i);
        if (self.cover.len < n) {
            const fresh = self.gpa.alloc(f32, n) catch return;
            if (self.cover.len > 0) self.gpa.free(self.cover);
            self.cover = fresh;
        }
        const row = self.cover[0..n];

        const sub: u32 = 4;
        const w = 1.0 / @as(f32, @floatFromInt(sub));

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            @memset(row, 0);
            var s: u32 = 0;
            while (s < sub) : (s += 1) {
                const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) * w;
                self.xs.clearRetainingCapacity();
                // One loop PER SUBPATH, closing each back to its own first
                // point. A subpath with fewer than three points encloses no
                // area, so it contributes nothing to either rule.
                var si: usize = 0;
                while (si < starts.len) : (si += 1) {
                    const s0 = starts[si];
                    const s1 = if (si + 1 < starts.len) starts[si + 1] else pts.len;
                    if (s0 >= s1 or s1 > pts.len or s1 - s0 < 3) continue;
                    var i: usize = s0;
                    while (i < s1) : (i += 1) {
                        const a = pts[i];
                        const b = pts[if (i + 1 == s1) s0 else i + 1];
                        const da = a[1] <= sy;
                        const db = b[1] <= sy;
                        if (da == db) continue;
                        const t = (sy - a[1]) / (b[1] - a[1]);
                        const cxx = a[0] + t * (b[0] - a[0]);
                        self.xs.append(self.gpa, .{ .x = cxx, .dir = if (b[1] > a[1]) 1 else -1 }) catch return;
                    }
                }
                const crossings = self.xs.items;
                if (crossings.len < 2) continue;
                std.mem.sort(Cross, crossings, {}, Cross.lessThan);

                if (rule == .evenodd) {
                    var k: usize = 0;
                    while (k + 1 < crossings.len) : (k += 2) {
                        addSpan(row, x0i, crossings[k].x, crossings[k + 1].x, w);
                    }
                } else {
                    var wind: i32 = 0;
                    var from: f32 = 0;
                    for (crossings) |c| {
                        const was = wind;
                        wind += c.dir;
                        if (was == 0 and wind != 0) {
                            from = c.x;
                        } else if (was != 0 and wind == 0) {
                            addSpan(row, x0i, from, c.x, w);
                        }
                    }
                }
            }

            var px = x0i;
            while (px < x1i) : (px += 1) {
                const cov = row[@intCast(px - x0i)];
                if (cov <= 0) continue;
                self.blendCoverage(px, y, fill.colorAt(
                    box,
                    @as(f32, @floatFromInt(px)) + 0.5,
                    @as(f32, @floatFromInt(y)) + 0.5,
                ), @min(cov, 1));
            }
        }
    }

    /// Add one horizontal span's exact overlap to the coverage row.
    fn addSpan(row: []f32, x0i: i64, x0_in: f32, x1_in: f32, w: f32) void {
        const base: f32 = @floatFromInt(x0i);
        const end: f32 = base + @as(f32, @floatFromInt(row.len));
        const xa = @max(x0_in, base);
        const xb = @min(x1_in, end);
        if (xb <= xa) return;
        var pxi: i64 = @intFromFloat(@floor(xa));
        const last: i64 = @as(i64, @intFromFloat(@ceil(xb))) - 1;
        while (pxi <= last) : (pxi += 1) {
            const l = @max(xa, @as(f32, @floatFromInt(pxi)));
            const r = @min(xb, @as(f32, @floatFromInt(pxi + 1)));
            if (r > l) {
                const idx: usize = @intCast(pxi - x0i);
                if (idx < row.len) row[idx] += (r - l) * w;
            }
        }
    }

    pub fn roundRectClip(self: *Self, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool, clip: elmz.Rect) void {
        // The corner geometry comes from the unclipped rect on purpose: a clip
        // is a window over the shape, never a change to the shape.
        const r = @min(radius, @min(rect.w, rect.h) * 0.5);
        if (r <= 0) {
            if (!stroke) return self.fillRectClip(rect, fill, clip);
            // A solid square outline really is four quads, and emit draws it
            // that way. A GRADIENT one cannot be: each quad's box is 1px on
            // its short axis, so the ramp would restart per edge. Those fall
            // through to the SDF below with r = 0, which is a box.
            if (fill.isSolid()) return;
        }
        const hx = rect.w * 0.5 - r;
        const hy = rect.h * 0.5 - r;
        const cx = rect.x + rect.w * 0.5;
        const cy = rect.y + rect.h * 0.5;

        const sp = self.clipSpan(rect, clip) orelse return;

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                var cov = std.math.clamp(0.5 - d, 0, 1);
                if (stroke) cov -= std.math.clamp(0.5 - (d + 1.0), 0, 1);
                if (cov > 0) self.blendCoverage(x, y, fill.colorAt(
                    rect,
                    @as(f32, @floatFromInt(x)) + 0.5,
                    @as(f32, @floatFromInt(y)) + 0.5,
                ), cov);
            }
        }
    }

    /// A glow or shadow: the same signed distance the rounded rect is built
    /// from, with the coverage term swapped for a falloff that straddles the
    /// edge -- solid `blur / 2` inside it, gone `blur / 2` outside.
    ///
    /// Only the ring is walked. The interior is fully opaque by construction
    /// and the element paints over it, so looping over it would be work whose
    /// result is never seen. That keeps a glow's cost proportional to its
    /// circumference rather than to the area it wraps.
    pub fn halo(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        if (h.color.a == 0) return;
        // Explicit beats the default. A quality setting the library can
        // second-guess is not an escape hatch, so `.sdf` is honoured even where
        // a stencil would be cheaper.
        //
        // Two paths, no policy: `baked` is the default value and the fast one,
        // and there is no size threshold left to second-guess it. A heuristic
        // that "improves" the default is the thing that made a low-blur halo
        // slow for a year, so the choice is the caller's or nobody's.
        // The old rule sent blur < 10 to the distance field on the argument
        // that "the ramp has few pixels left to cache, and baking would cost
        // more than it saves". That was reasoning about a mask the size of the
        // shape. Slicing made a bake independent of area, and the benchmark
        // then inverted it at every blur measured, cold as well as hot:
        //
        //     blur    sdf hot   baked cold   baked hot
        //        4      68.5us       45.7us       39.0us
        //       24     152.6us      108.8us       88.2us
        //       40     219.5us      147.4us      106.2us
        //
        // The one case left that could favour the field is cache pressure, so
        // it was measured too: 16 distinct silhouettes redrawn every frame
        // (past the 8-entry cache, so LRU misses on every halo) still costs
        // 0.915ms baked against 1.202ms for the field. Nothing is left for a
        // heuristic to protect.
        // A stencil is keyed on the silhouette alone, so it cannot carry the cut
        // that turns an offset or grown rim into a shadow: the element's own
        // outline is not in the key. Those cases take the field.
        const geometric_cut = h.mode == .outer_glow and (h.offset[0] != 0 or h.offset[1] != 0 or h.spread != 0);
        const use_sdf = h.light != null or geometric_cut or switch (h.quality) {
            .sdf => true,
            .baked => false,
        };
        // The blended metric depends on the shape's own aspect, and a stencil is
        // keyed on (radius, blur, corner) with no width or height in the key: a
        // template baked from one silhouette and stretched across another would
        // carry the wrong ellipse. Cheap to give up -- this is the mode that is
        // already the widest band, and a wide band is where a bake saved least.
        if (use_sdf) return self.haloSdf(rect, corner, h, clip);
        self.haloBaked(rect, corner, h, clip);
    }

    fn haloSdf(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const blur = @max(h.blur, 0);
        // The silhouette the ramp runs away from, after spread and offset.
        // An inner glow never moves its silhouette. Shrinking it for `spread`
        // (the first attempt) put the bright band three pixels inside the face, so
        // the rim floated off the edge it is supposed to light and the button read
        // as a stripe across the middle. Growing it instead throws light outside
        // the element. So the shape stays the element and `spread` becomes what it
        // says -- a flat core -- by holding the ramp at full brightness for that
        // many pixels before it begins to decay.
        const spread = if (h.mode == .inner_glow) 0 else h.spread;
        const shape = elmz.Rect{
            .x = rect.x + h.offset[0] - spread,
            .y = rect.y + h.offset[1] - spread,
            .w = rect.w + spread * 2,
            .h = rect.h + spread * 2,
        };
        if (shape.w <= 0 or shape.h <= 0) return;
        const r = @min(@max(corner + spread, 0), @min(shape.w, shape.h) * 0.5);
        const hx = shape.w * 0.5 - r;
        const hy = shape.h * 0.5 - r;
        const cx = shape.x + shape.w * 0.5;
        const cy = shape.y + shape.h * 0.5;

        // The element's own outline, before spread and offset: an outer rim is cut
        // against THIS, so a displaced shadow still fills the strip between the
        // element and its silhouette instead of leaving a gap there.
        const er = @min(@max(corner, 0), @min(rect.w, rect.h) * 0.5);
        const ehx = rect.w * 0.5 - er;
        const ehy = rect.h * 0.5 - er;
        const ecx = rect.x + rect.w * 0.5;
        const ecy = rect.y + rect.h * 0.5;

        // The direction the shadow is thrown. A light at clock `deg` sits on that
        // side and travels toward the shape, so the cast points the opposite way:
        // at 0 the lamp is overhead and the cast points to +y.
        var cast: [2]f32 = .{ 0, 0 };
        if (h.light) |deg| {
            const a = deg * std.math.pi / 180.0;
            cast = .{ -@sin(a), @cos(a) };
        }

        // Ring bounds: the shape grown by the falloff, plus one pixel for the
        // antialiased edge itself. A lit ramp reaches further on the cast side.
        const grow: f32 = falloffReach(h.mode, blur, h.light != null) + 1;
        const ring = elmz.Rect{
            .x = shape.x - grow,
            .y = shape.y - grow,
            .w = shape.w + grow * 2,
            .h = shape.h + grow * 2,
        };
        // A rim light keeps the shape where it MEETS it and loses it as it decays
        // inward. That is the whole of `circularity`'s gate: zero for a narrow rim,
        // which is tracing the outline and should keep the corners it is attached
        // to, rising as the falloff becomes a real fraction of the shape.
        //
        // Only inner glows blend. An outward ramp already rounds itself off without
        // help: growing `blur/2` on every side takes an 80x60 box from 1.27 aspect
        // to 1.14 and the corner radius grows with it, so its tail is round already.
        const circular: f32 = if (h.mode == .inner_glow) circularity(shape.w, shape.h, blur) else 0;
        const ea = shape.w * 0.5;
        const eb = shape.h * 0.5;
        // Depth is measured against the reach actually available, not against
        // `blur` alone: on a face shorter than the falloff the ramp never gets to
        // run its full length, and normalising by `blur` there would leave the
        // blend at a fraction of where it needs to be. `min` of the two means the
        // tail is fully pooled by the time the glow reaches the middle, whichever
        // is smaller.
        const reach = @min(blur, @min(ea, eb));

        const sp = self.clipSpan(ring, clip) orelse return;

        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                // Nothing to draw once the ramp has run out, and nothing to
                // draw deep inside: the shape is opaque there.
                // Cutting an outer rim against the element is a silhouette, so it
                // has to be feathered like one. A binary inside/outside test steps
                // a whole pixel; the fill underneath was antialiased against the
                // background and the rim is bright, so that single step is the
                // rough edge. `cut` is the element's own coverage inverted: the rim
                // keeps whatever the fill did not cover.
                var cut: f32 = 1;
                if (h.mode == .outer_glow) {
                    const ex = @abs(@as(f32, @floatFromInt(x)) + 0.5 - ecx) - ehx;
                    const ey = @abs(@as(f32, @floatFromInt(y)) + 0.5 - ecy) - ehy;
                    const de = @sqrt(@max(ex, 0) * @max(ex, 0) + @max(ey, 0) * @max(ey, 0)) + @min(@max(ex, ey), 0) - er;
                    if (de < -1) continue;
                    cut = std.math.clamp(0.5 + de, 0, 1);
                }
                // Depth-gated blend: at the boundary the metric IS the shape's, so
                // the rim sits on the corners it belongs to; by the far end of the
                // falloff it has become the inscribed ellipse, which has none.
                var rd = d;
                if (circular > 0) {
                    const t = std.math.clamp(-d / reach, 0, 1) * circular;
                    rd = d + (ellipseDistance(px, py, ea, eb) - d) * t;
                }
                const w = if (h.light != null) lightWidth(blur, px, py, hx, hy, cast) else blur;
                // A flat core is a depth offset, not a bigger shape: the rim still
                // starts on the element edge, it just stays at full brightness for
                // `spread` before it starts to decay.
                const core: f32 = if (h.mode == .inner_glow) h.spread else 0;
                var cov = ramp(h.mode, rd, w, core);
                if (cov > 0) {
                    cov *= switch (h.mode) {
                        // The rim lives on the face, so it has to stop where the
                        // face stops -- and the face's own edge is antialiased.
                        // Multiply by the coverage the fill would have at this
                        // pixel and the rim composites exactly as if it were part
                        // of the fill.
                        //
                        // This feather was removed once before and deserved to be:
                        // it was measuring against the INSET silhouette, so the
                        // half-strength ring landed three pixels inside the face, in
                        // the middle of the rim, and read as a seam. The shape is
                        // the element now, so it lands on the edge.
                        // A fill edge gets away with one pixel of linear coverage
                        // because it meets a background of similar value. This rim
                        // sits at PEAK brightness exactly where the face meets the
                        // page, so there is no brightness gradient to carry the eye
                        // and a single erratic pixel reads as a stair around the
                        // corner arc (measured: 0.64, 0.18, 0.91, 0.18 down the arc
                        // at radius 8). Two pixels of smoothstep gives the boundary
                        // something to walk down. It costs a faint 1px bleed outside
                        // the face, which is what an antialiased edge is.
                        // The rim must not be what defines the silhouette. It peaks
                        // a pixel and a half INSIDE the face and fades to nothing at
                        // the geometric edge, so the element's own fill -- drawn
                        // underneath and antialiased like every other fill -- owns the
                        // outermost pixel. Measured before this: the boundary pixel
                        // carried 103 against a 37 backdrop, so any arc error was at
                        // maximum contrast. This is a taper, not the rejected inset
                        // silhouette: the rim still hugs the edge, it just no longer
                        // IS the edge.
                        .inner_glow => blk: {
                            const t = std.math.clamp(-d / 1.5, 0, 1);
                            break :blk t * t * (3 - 2 * t);
                        },
                        .glow => 1,
                        .outer_glow => cut,
                    };
                }
                if (cov > 0) self.blendCoverage(x, y, h.color, cov);
            }
        }
    }

    /// Blur the destination under `rect`, in place, then blend the result back
    /// through the rounded-rect coverage so a frosted card keeps its corners.
    ///
    /// Reads AND writes the canvas, which is the whole reason a frost is recorded
    /// before the element's own fill: what it frosts is what is underneath.
    ///
    /// Sampling clamps at the region's own edge rather than reaching outside it.
    /// That is what stops a frosted panel dragging black in from beyond its
    /// bounds, and it is why the region is the element's FULL rect, not its inset
    /// content box: the outermost row is then a little less blurred than the
    /// middle, the same trade CSS backdrop filters make.
    pub fn frost(self: *Self, rect: elmz.Rect, radius: f32, blur: f32, clip: elmz.Rect) void {
        if (blur <= 0) return;
        const region = rect.intersect(clip);
        if (region.isEmpty()) return;
        const sp = self.clipSpan(region, clip) orelse return;
        const w: usize = @intCast(sp.x1 - sp.x0);
        const h: usize = @intCast(sp.y1 - sp.y0);
        if (w == 0 or h == 0) return;

        const buf = self.gpa.alloc(u8, w * h * 4) catch return;
        defer self.gpa.free(buf);
        const scratch = self.gpa.alloc(u8, @max(w, h) * 4) catch return;
        defer self.gpa.free(scratch);

        // Span bounds are i64 because a clip can reach outside the canvas; the
        // region itself is already intersected, so the cast is a narrowing to a
        // value that provably fits.
        const x0: usize = @intCast(sp.x0);
        const y0: usize = @intCast(sp.y0);

        // Copy out first: a blur reads neighbours and cannot run in place.
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const di = ((y0 + y) * self.w + x0) * 4;
            @memcpy(buf[y * w * 4 ..][0 .. w * 4], self.px[di..][0 .. w * 4]);
        }

        // Three box passes on alternating axes: close enough to a Gaussian that
        // the difference is invisible at these radii, and O(pixels) instead of
        // O(pixels * radius).
        const rad: usize = @intFromFloat(@max(@round(blur * 0.5), 1));
        boxBlur(buf, w, h, rad, true, scratch);
        boxBlur(buf, w, h, rad, false, scratch);
        boxBlur(buf, w, h, rad, true, scratch);

        // Blend back through the shape's own coverage: 1 replaces the pixel with
        // the blurred one, 0 leaves it, and the antialiased edge and rounded
        // corners fall out of the same distance field the fill uses.
        const r = @min(@max(radius, 0), @min(rect.w, rect.h) * 0.5);
        const hx = rect.w * 0.5 - r;
        const hy = rect.h * 0.5 - r;
        const cx = rect.x + rect.w * 0.5;
        const cy = rect.y + rect.h * 0.5;
        y = 0;
        while (y < h) : (y += 1) {
            const py = @as(f32, @floatFromInt(y0 + y)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const px = @as(f32, @floatFromInt(x0 + x)) + 0.5 - cx;
                const qx = @abs(px) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                const cov = std.math.clamp(0.5 - d, 0, 1);
                if (cov <= 0) continue;
                const o = (y * w + x) * 4;
                // The blurred RGB, composited with `cov` as its alpha. The
                // buffer's own alpha is ignored: a frost over a transparent
                // backdrop has no colour to show, which is one reason it pairs
                // with a translucent fill rather than replacing one.
                self.blendPixel(@intCast(x0 + x), @intCast(y0 + y), .{
                    .r = buf[o],
                    .g = buf[o + 1],
                    .b = buf[o + 2],
                    .a = @intFromFloat(cov * 255 + 0.5),
                });
            }
        }
    }

    /// Replay a recorded frame onto the pixels. `Runtime.frame` only records
    /// primitives; nothing is rasterised until this runs.
    pub fn paintFrame(self: *Self, prims: []const elmz.Primitive) void {
        const r = self.renderer();
        for (prims) |p| switch (p) {
            .quad => |q| r.quad(q.rect, q.fill, q.clip),
            .halo => |q| r.halo(q.rect, q.corner, q.halo, q.clip),
            .frost => |q| r.frost(q.rect, q.radius, q.blur, q.clip),
            .rrect => |q| r.roundedRect(q.rect, q.radius, q.fill, q.stroke, q.clip),
            .text => |t| r.text(t.x, t.y, t.size, t.fill, t.bytes, t.clip),
        };
    }

    /// Copy `src` into this canvas with its top-left at `at`, compositing by
    /// `src`'s alpha.
    ///
    /// The 4-byte RGBA stride is this file's business, so callers should never
    /// restate it -- that is how the two previous hand-written copies of this
    /// loop ended up in example `main`s. Anything that would land outside the
    /// destination is dropped rather than erroring: compositing a contact sheet
    /// is the use, and a half-visible tile is more useful than a fatal error.
    ///
    /// This was a `@memcpy` until a transparent source was needed, which is the
    /// one thing a straight copy cannot do: it writes the source's alpha over
    /// the destination's instead of blending into it. A fully opaque source row
    /// still takes the memcpy path, so the common case -- tiles, snapshots --
    /// stays byte-identical to the canvas it came from and pays nothing.
    pub fn blitFrom(self: *Self, src: *const Self, at: [2]u32) void {
        if (at[0] >= self.w or at[1] >= self.h) return;
        const copy_w: usize = @min(src.w, self.w - at[0]);
        const copy_h: usize = @min(src.h, self.h - at[1]);
        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            // usize throughout: w*h*4 overflows u32 on any canvas worth blitting.
            const dst_i = ((@as(usize, at[1]) + y) * self.w + at[0]) * 4;
            const src_i = (y * src.w) * 4;
            const drow = self.px[dst_i..][0 .. copy_w * 4];
            const srow = src.px[src_i..][0 .. copy_w * 4];
            if (rowOpaque(srow)) {
                @memcpy(drow, srow);
                continue;
            }
            var x: usize = 0;
            while (x < copy_w) : (x += 1) {
                const o = x * 4;
                if (srow[o + 3] == 0) continue; // invisible: leave the destination alone
                composite(drow[o..][0..4], srow[o..][0..4]);
            }
        }
    }

    /// Baked path: same ramp, sampled from a stencil instead of computed.
    ///
    /// The stencil is built in the shape's own space, so `offset` moves the
    /// blit and never the bake. A silhouette that would need an absurd mask
    /// falls back to the distance field rather than allocating it.
    fn haloBaked(self: *Self, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const blur = @max(h.blur, 0);
        // Insets for an inner glow; see `haloSdf`.
        const spread = if (h.mode == .inner_glow) 0 else h.spread;
        const shape = elmz.Rect{
            .x = rect.x + h.offset[0] - spread,
            .y = rect.y + h.offset[1] - spread,
            .w = rect.w + spread * 2,
            .h = rect.h + spread * 2,
        };
        if (shape.w <= 0 or shape.h <= 0) return;
        const r = @min(@max(corner + spread, 0), @min(shape.w, shape.h) * 0.5);
        const swi: i32 = @intFromFloat(@round(shape.w));
        const shi: i32 = @intFromFloat(@round(shape.h));
        const m = self.maskFor(swi, shi, r, blur, h.mode, if (h.mode == .inner_glow) h.spread else 0) orelse return self.haloSdf(rect, corner, h, clip);

        const grow = falloffReach(h.mode, blur, false) + 1;
        // A template describes any size, so the target ring is computed here;
        // a whole stencil already knows how big it is.
        // A slice template and a tiled entry both describe a RANGE of silhouettes,
        // so the ring is computed at the target size; a whole stencil already knows
        // how big it is and must keep its own dimensions or the blit drifts.
        const hollow = m.sw == 0 or m.tiled;
        const rw: u32 = if (hollow)
            @intFromFloat(@ceil(@as(f32, @floatFromInt(swi)) + grow * 2))
        else
            m.rw;
        const rh: u32 = if (hollow)
            @intFromFloat(@ceil(@as(f32, @floatFromInt(shi)) + grow * 2))
        else
            m.rh;

        const ox: i64 = @intFromFloat(@round(shape.x - grow));
        const oy: i64 = @intFromFloat(@round(shape.y - grow));
        const ring = elmz.Rect{
            .x = @floatFromInt(ox),
            .y = @floatFromInt(oy),
            .w = @floatFromInt(rw),
            .h = @floatFromInt(rh),
        };
        const sp = self.clipSpan(ring, clip) orelse return;

        // Sliced per axis, not per entry: a slice template repeats both, a tiled
        // entry repeats x only.
        const sliced_x = m.sw == 0 or m.tiled;
        const sliced_y = m.sw == 0;
        const c = m.corner;
        var y = sp.y0;
        while (y < sp.y1) : (y += 1) {
            const j = y - oy;
            if (j < 0 or j >= rh) continue;
            const uj: u32 = @intCast(j);
            // Rows inside the corner band are copied; the band between them is
            // one stretched row, which is the middle row of the template.
            // The stretched middle samples the template's CENTRE, not the
            // corner band's last column. `corner` is only `r + 1` px inside the
            // shape edge, so on a wide blur it is still mid-ramp: at blur 24 and
            // r 8 that column is 0.875 coverage, and stretching it pinned the
            // whole interior to 0.875 while the distance field drew 1.0 -- a
            // 21/255 step across the middle of every large halo.
            const sj: u32 = if (!sliced_y)
                uj
            else if (uj < c)
                uj
            else if (uj >= rh - c)
                m.rh - 1 - (rh - 1 - uj)
            else
                m.rh / 2;
            const row = m.px[@as(usize, sj) * m.rw ..][0..m.rw];
            var x = sp.x0;
            while (x < sp.x1) : (x += 1) {
                const i = x - ox;
                if (i < 0 or i >= rw) continue;
                const ui: u32 = @intCast(i);
                const si: u32 = if (!sliced_x)
                    ui
                else if (ui < c)
                    ui
                else if (ui >= rw - c)
                    m.rw - 1 - (rw - 1 - ui)
                else
                    m.rw / 2;
                const a = row[si];
                if (a == 0) continue;
                self.blendCoverage(x, y, h.color, @as(f32, @floatFromInt(a)) / 255.0);
            }
        }
    }

    /// The stencil for one silhouette, built on first use and kept.
    ///
    /// Large silhouettes get a 9-SLICE TEMPLATE instead of a full mask. The
    /// coverage at the middle of an edge depends only on the distance from
    /// that edge, and the interior is solid, so one small square describes
    /// every size at a given radius and blur. `w` and `h` therefore drop out of
    /// the key -- which is the real prize: a view full of differently-sized
    /// glowing rows used to evict every mask every frame and bake forever.
    /// Memory is the side effect, not the point.
    ///
    /// Silhouettes too small to slice still get a full bake, so the cache holds
    /// two shapes of entry.
    fn maskFor(self: *Self, sw: i32, sh: i32, r: f32, blur: f32, mode: elmz.Halo.Mode, spread: f32) ?*Mask {
        if (sw <= 0 or sh <= 0) return null;
        const grow = falloffReach(mode, blur, false) + 1;
        // The corner band has to reach PAST the ramp, not just past the arc.
        // Stretching one column across the interior is only sound where the
        // coverage stops varying with distance from the edge, and for a glow that
        // is `blur / 2` inside, not `r`. At blur 24 and r 8 the old band stopped
        // 9.5px inside -- mid-ramp -- so a large halo repeated a 0.896 column
        // across its whole face and painted full opacity where the distance field
        // drew a falloff. That is the baked-looks-bigger report: the step was 21
        // of 255 across the middle of every sliced glow.
        const corner: u32 = @intFromFloat(@ceil(grow + @max(r, blur * 0.5) + 1));

        // The template's centre column is the value `corner` pixels in, and the
        // blit stretches it across the whole interior. That is only sound where
        // the interior is SATURATED -- true for a glow and for a shadow, whose
        // ramp is fully opaque well inside the edge. An `.inner_glow` ramps the
        // other way and is fully TRANSPARENT in the interior, so `corner` lands
        // mid-ramp and stretching it pins the inside to a constant ~0.32: the
        // rim stops falling off and the middle of the shape never goes empty.
        // Inner glows are therefore never sliced.
        const sliceable = mode != .inner_glow and sw >= @as(i32, @intCast(corner * 2)) and sh >= @as(i32, @intCast(corner * 2));
        if (sliceable) {
            for (self.masks.items) |*m| {
                if (m.sw == 0 and m.r == r and m.blur == blur and m.corner == corner and m.mode == mode) return m;
            }
            // The template is a bake of a shape exactly large enough that its
            // two corner bands meet and the middle is the solid interior.
            const tsw: i32 = @intCast(corner * 2 + 1);
            const rw: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(tsw)) + grow * 2));
            if (@as(u64, rw) * @as(u64, rw) > 4_000_000) return null;
            const px = self.gpa.alloc(u8, @as(usize, rw) * rw) catch return null;
            bakeStencil(px, rw, rw, tsw, tsw, r, blur, grow, mode, 0);
            self.bakes += 1;
            return self.admit(px, .{ .sw = 0, .sh = 0, .r = r, .blur = blur, .mode = mode, .corner = corner, .rw = rw, .rh = rw });
        }

        // AN INNER RIM REPEATS ALONG ONE AXIS, NOT TWO.
        //
        // Past `blur` in from the left and right edges the field stops depending
        // on x altogether, so the centre column is not an approximation of those
        // pixels -- for them it IS the answer. Height cannot be repeated the same
        // way: on a face shorter than its own falloff the top and bottom ramps
        // overlap and meet in the middle, and a stretched row erases exactly that
        // convergence. So bake the height true, the corner bands true, and repeat
        // only the columns between them. The template is made just wide enough
        // that its own centre column is already past the x-independent boundary.
        if (mode == .inner_glow and sw >= @as(i32, @intCast(corner * 2 + 2))) {
            // Width from the aspect bucket, floored at the width that clears both
            // corner bands. The bucket is in the KEY, via `sw`, so a second width
            // near this one reuses the entry and a far-off aspect gets its own.
            const aspect = aspectBucket(@as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(sh)));
            var tsw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(sh)) * aspect));
            tsw = @max(tsw, @as(i32, @intCast(corner * 2 + 1)));
            for (self.masks.items) |*m| {
                if (m.tiled and m.sw == tsw and m.sh == sh and m.r == r and m.blur == blur and m.core == spread and m.mode == mode) return m;
            }
            const rw: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(tsw)) + grow * 2));
            const rh: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(sh)) + grow * 2));
            if (@as(u64, rw) * @as(u64, rh) > 4_000_000) return null;
            const px = self.gpa.alloc(u8, @as(usize, rw) * rh) catch return null;
            bakeStencil(px, rw, rh, tsw, sh, r, blur, grow, mode, spread);
            self.bakes += 1;
            return self.admit(px, .{ .sw = tsw, .sh = sh, .r = r, .blur = blur, .mode = mode, .corner = corner, .tiled = true, .core = spread, .rw = rw, .rh = rh });
        }

        for (self.masks.items) |*m| {
            if (m.sw == sw and m.sh == sh and m.r == r and m.blur == blur and m.mode == mode) return m;
        }
        const rw: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(sw)) + grow * 2));
        const rh: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(sh)) + grow * 2));
        if (@as(u64, rw) * @as(u64, rh) > 4_000_000) return null;
        const px = self.gpa.alloc(u8, @as(usize, rw) * rh) catch return null;
        bakeStencil(px, rw, rh, sw, sh, r, blur, grow, mode, spread);
        self.bakes += 1;
        return self.admit(px, .{ .sw = sw, .sh = sh, .r = r, .blur = blur, .mode = mode, .rw = rw, .rh = rh });
    }

    /// Install a baked stencil, evicting the eldest when the cache is full.
    fn admit(self: *Self, px: []u8, entry: Mask) ?*Mask {
        if (self.masks.items.len >= 8) {
            const old = self.masks.orderedRemove(0);
            self.gpa.free(old.px);
        }
        self.masks.append(self.gpa, .{
            .sw = entry.sw,
            .sh = entry.sh,
            .r = entry.r,
            .blur = entry.blur,
            // The mode is part of the key, so an entry that forgets which side of
            // the silhouette it carries is not just mislabelled -- it can never be
            // found again. Every lookup for a non-glow mode missed and re-baked.
            .mode = entry.mode,
            .corner = entry.corner,
            .tiled = entry.tiled,
            .core = entry.core,
            .rw = entry.rw,
            .rh = entry.rh,
            .px = px,
        }) catch {
            self.gpa.free(px);
            return null;
        };
        return &self.masks.items[self.masks.items.len - 1];
    }

    /// Coverage of one rounded-rect silhouette grown by `grow` on every side,
    /// into a `rw` x `rh` buffer. The shape's own top-left lands at
    /// (grow, grow), which is what lets a template's corner band be copied
    /// straight out at any target size.
    fn bakeStencil(px: []u8, rw: u32, rh: u32, sw: i32, sh: i32, r: f32, blur: f32, grow: f32, mode: elmz.Halo.Mode, core: f32) void {
        // An inner rim is the one mode whose field is not local to the edge: it
        // runs a full `blur` in, and past `blur` in from every side the metric
        // stops being the shape's distance and becomes the inscribed ellipse.
        // Both terms are baked, so a stencil reproduces the field path rather
        // than an approximation of it.
        const swf = @as(f32, @floatFromInt(sw));
        const shf = @as(f32, @floatFromInt(sh));
        const circular: f32 = if (mode == .inner_glow) circularity(swf, shf, blur) else 0;
        const ea = swf * 0.5;
        const eb = shf * 0.5;
        const reach = @min(blur, @min(ea, eb));
        const hx = @as(f32, @floatFromInt(sw)) * 0.5 - r;
        const hy = @as(f32, @floatFromInt(sh)) * 0.5 - r;
        const cx = grow + @as(f32, @floatFromInt(sw)) * 0.5;
        const cy = grow + @as(f32, @floatFromInt(sh)) * 0.5;
        var j: u32 = 0;
        while (j < rh) : (j += 1) {
            const py = @as(f32, @floatFromInt(j)) + 0.5 - cy;
            const qy = @abs(py) - hy;
            const ay = @max(qy, 0);
            var i: u32 = 0;
            while (i < rw) : (i += 1) {
                const pxx = @as(f32, @floatFromInt(i)) + 0.5 - cx;
                const qx = @abs(pxx) - hx;
                const ax = @max(qx, 0);
                const d = @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
                var rd = d;
                if (circular > 0) {
                    const t = std.math.clamp(-d / reach, 0, 1) * circular;
                    rd = d + (ellipseDistance(pxx, py, ea, eb) - d) * t;
                }
                const core_now: f32 = if (mode == .inner_glow) core else 0;
                var cov = ramp(mode, rd, blur, core_now);
                // An outer rim is cut against the element's own silhouette, and
                // this bake only ever runs when that silhouette IS the element:
                // any offset or spread takes `geometric_cut` and forces the field
                // path. Baking the cut here is what stops a baked outer rim from
                // lighting its own face, which is the whole difference between
                // `.outer_glow` and `.glow`.
                if (mode == .outer_glow) cov *= std.math.clamp(0.5 + d, 0, 1);
                // The taper is part of the field path, not part of `ramp`, so a
                // stencil has to carry it separately or a baked rim draws its
                // boundary pixel at full strength. That is not cosmetic: the taper
                // exists so the element's own antialiased fill owns the outermost
                // pixel, and without it the corner arc stair comes back -- in baked
                // mode only, which is the default.
                if (mode == .inner_glow) {
                    const t = std.math.clamp(-d / 1.5, 0, 1);
                    cov *= t * t * (3 - 2 * t);
                }
                px[@as(usize, j) * rw + i] = @intFromFloat(cov * 255.0 + 0.5);
            }
        }
    }

    /// True when every pixel in a row of RGBA bytes is fully opaque.
    fn rowOpaque(row: []const u8) bool {
        var i: usize = 3;
        while (i < row.len) : (i += 4) {
            if (row[i] != 255) return false;
        }
        return true;
    }

    /// Source-over one pixel, straight (non-premultiplied) alpha.
    ///
    /// Destination alpha is tracked rather than assumed opaque: a canvas made
    /// by `init` starts at alpha 0, and compositing onto one of those is the
    /// case that silently produced black before. With an opaque destination
    /// this reduces to `blendPixel`'s arithmetic, so a composited blit and a
    /// painted quad of the same colour land on the same byte.
    fn composite(dst: *[4]u8, src: *const [4]u8) void {
        const sa: f32 = @as(f32, @floatFromInt(src[3])) / 255.0;
        const da: f32 = @as(f32, @floatFromInt(dst[3])) / 255.0;
        const out_a: f32 = sa + da * (1 - sa);
        if (out_a <= 0) {
            dst.* = .{ 0, 0, 0, 0 };
            return;
        }
        const dst_w: f32 = da * (1 - sa);
        inline for (0..3) |ch| {
            // In light, like every other composite. A blit and a painted quad
            // of the same colour and alpha have to land on the same byte, and
            // they only do if both are summed in the same space.
            const s = gamma.to_linear[src[ch]];
            const d = gamma.to_linear[dst[ch]];
            dst[ch] = gamma.encode((s * sa + d * dst_w) / out_a);
        }
        dst[3] = toByte(out_a * 255.0);
    }

    /// `@intFromFloat` traps outside the type, and a rounding error one ulp
    /// above 255 would be a crash in the paint loop rather than a wrong pixel.
    fn toByte(v: f32) u8 {
        return @intFromFloat(@min(255.0, @max(0.0, v)));
    }

    /// Encode to PNG and write it to the working directory.
    ///
    /// Every example wants exactly this, and the two-line version is easy to
    /// get subtly wrong: `encodePng` returns owned bytes that must survive
    /// until after the write.
    pub fn writePng(self: *const Self, io: std.Io, gpa: Allocator, name: []const u8) !void {
        const png = try self.encodePng(gpa);
        defer gpa.free(png);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = png });
    }

    // -- the elmz.Renderer vtable -------------------------------------------

    pub fn renderer(self: *Self) elmz.Renderer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = elmz.Renderer.VTable{
        .quad = vtQuad,
        .path = vtPath,
        .rrect = vtRrect,
        .text = vtText,
        .halo = vtHalo,
        .frost = vtFrost,
        .measure_text = vtMeasure,
        .wrap_text = vtWrap,
        .advance_text = vtAdvanceText,
        .hit_text = vtHitText,
    };

    fn vtFrost(ptr: *anyopaque, rect: elmz.Rect, radius: f32, blur: f32, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.frost(
            self.scaledRect(rect),
            radius * self.scale,
            blur * self.scale,
            self.scaledRect(clip),
        );
    }

    fn vtHalo(ptr: *anyopaque, rect: elmz.Rect, corner: f32, h: elmz.Halo, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var d = h;
        if (self.scale != 1.0) {
            d.blur = h.blur * self.scale;
            d.spread = h.spread * self.scale;
            d.offset = .{ h.offset[0] * self.scale, h.offset[1] * self.scale };
        }
        self.halo(self.scaledRect(rect), corner * self.scale, d, self.scaledRect(clip));
    }

    fn vtQuad(ptr: *anyopaque, rect: elmz.Rect, fill: elmz.Fill, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.fillRectClip(self.scaledRect(rect), fill, self.scaledRect(clip));
    }

    fn vtRrect(ptr: *anyopaque, rect: elmz.Rect, radius: f32, fill: elmz.Fill, stroke: bool, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.roundRectClip(
            self.scaledRect(rect),
            radius * self.scale,
            fill,
            stroke,
            self.scaledRect(clip),
        );
    }

    fn vtText(ptr: *anyopaque, x: f32, y: f32, size: f32, fill: elmz.Fill, bytes: []const u8, clip: elmz.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.drawTextClip(
            x * self.scale,
            y * self.scale,
            size * self.scale,
            fill,
            bytes,
            self.scaledRect(clip),
        );
    }

    /// Font metrics for one string, cached. `dev` is the DEVICE size; the
    /// divide-back for HiDPI happens at the call site, so what is stored is the
    /// number the glyphs were actually fitted at.
    ///
    /// The cache OWNS its key bytes. Pointing into the frame arena would dangle
    /// at the next frame's reset, which is the trap that makes a naive version
    /// corrupt rather than slow.
    fn cachedMeasure(self: *Self, bytes: []const u8, dev: f32) elmz.TextMetrics {
        const face = self.font.instanceKey();
        const probe: MeasureKey = .{ .text = bytes, .dev = dev, .face = face };
        if (self.measure_cache.get(probe)) |m| {
            self.measure_hits += 1;
            return m;
        }
        self.measure_misses += 1;
        const m = if (self.font.available()) self.font.measure(bytes, dev) else elmfont.measure(bytes, dev);
        if (self.measure_cache.count() >= measure_cap) self.clearMeasureCache();
        const owned = self.gpa.dupe(u8, bytes) catch return m;
        self.measure_cache.put(self.gpa, .{ .text = owned, .dev = dev, .face = face }, m) catch {
            self.gpa.free(owned);
            return m;
        };
        return m;
    }

    fn clearMeasureCache(self: *Self) void {
        var it = self.measure_cache.keyIterator();
        while (it.next()) |k| self.gpa.free(k.text);
        self.measure_cache.clearRetainingCapacity();
    }

    fn clearWrapCache(self: *Self) void {
        var it = self.wrap_cache.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.text);
            self.gpa.free(e.value_ptr.offsets);
        }
        self.wrap_cache.clearRetainingCapacity();
    }

    /// Where a paragraph breaks, cached like a measurement -- because wrapping
    /// IS measuring: it walks every glyph to find where a line can end. A
    /// wrapped label asks the same question more than once per frame (layout,
    /// the row fit, then paint), so the second and third ask are now free.
    fn cachedWrap(self: *Self, bytes: []const u8, dev: f32, max_w: f32, out: [][]const u8) usize {
        if (out.len == 0) return 0;
        const face = self.font.instanceKey();
        if (self.wrap_cache.get(.{ .text = bytes, .dev = dev, .max_w = max_w, .face = face })) |e| {
            self.wrap_hits += 1;
            const n = @min(e.n, out.len);
            for (0..n) |i| out[i] = bytes[e.offsets[2 * i]..e.offsets[2 * i + 1]];
            return n;
        }
        self.wrap_misses += 1;
        const n = if (self.font.available())
            self.font.wrapLines(bytes, dev, max_w, out)
        else
            elmfont.wrap(bytes, dev, max_w, out);
        if (self.wrap_cache.count() >= wrap_cap) self.clearWrapCache();
        // `wrapLines` returns subslices of `bytes`, so a break is an offset
        // into the text and never a pointer into anything borrowed.
        const owned = self.gpa.dupe(u8, bytes) catch return n;
        const offsets = self.gpa.alloc(u32, n * 2) catch {
            self.gpa.free(owned);
            return n;
        };
        for (out[0..n], 0..) |line, i| {
            const off: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(bytes.ptr));
            offsets[2 * i] = off;
            offsets[2 * i + 1] = off + @as(u32, @intCast(line.len));
        }
        self.wrap_cache.put(
            self.gpa,
            .{ .text = owned, .dev = dev, .max_w = max_w, .face = face },
            .{ .offsets = offsets, .n = n },
        ) catch {
            self.gpa.free(owned);
            self.gpa.free(offsets);
            return n;
        };
        return n;
    }

    /// Measured at the DEVICE size and divided back, never "measure logical and
    /// hope". Advances are not exactly linear in point size -- hinting and
    /// grid-fitting move stems by whole pixels -- so at 1.25x the width of a
    /// string is not 1.25x the width measured at 1x, and a layout built on the
    /// scaled-down number would disagree with the glyphs actually drawn.
    fn vtMeasure(ptr: *anyopaque, bytes: []const u8, size: f32) elmz.TextMetrics {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const m = self.cachedMeasure(bytes, size * self.scale);
        if (self.scale == 1.0) return m;
        const inv = 1.0 / self.scale;
        return .{
            .width = m.width * inv,
            .height = m.height * inv,
            .ascent = m.ascent * inv,
            .descent = m.descent * inv,
            .line_height = m.line_height * inv,
        };
    }

    /// Wrapping is decided in DEVICE space for the same reason measurement is:
    /// a line that fits at 1x can overflow at 1.5x, and the decision has to be
    /// made against the glyphs that will actually be rasterised.
    fn vtWrap(
        ptr: *anyopaque,
        bytes: []const u8,
        size: f32,
        max_width: f32,
        out: [][]const u8,
    ) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.scale == 1.0) return self.cachedWrap(bytes, size, max_width, out);
        return self.cachedWrap(bytes, size * self.scale, max_width * self.scale, out);
    }

    /// Advances are font units, so this is device space for the same reason
    /// measurement is: a caret placed from a logical-space sum drifts from the
    /// glyphs actually rasterised.
    fn vtAdvanceText(ptr: *anyopaque, bytes: []const u8, size: f32, index: usize) f32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.font.available()) return elmfont.advanceTo(bytes, size, index);
        const d = self.font.advanceTo(bytes, size * self.scale, index);
        return if (self.scale == 1.0) d else d / self.scale;
    }

    fn vtHitText(ptr: *anyopaque, bytes: []const u8, size: f32, x: f32) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.font.available()) return elmfont.hitText(bytes, size, x);
        if (self.scale == 1.0) return self.font.hitText(bytes, size, x);
        return self.font.hitText(bytes, size * self.scale, x * self.scale);
    }

    // -- PNG ----------------------------------------------------------------

    pub fn encodePng(self: *const Self, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const w = gpa;

        try out.appendSlice(w, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });

        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], self.w, .big);
        std.mem.writeInt(u32, ihdr[4..8], self.h, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // RGBA
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try writeChunk(w, &out, "IHDR", &ihdr);

        // raw scanlines with filter byte 0
        const stride: usize = @as(usize, self.w) * 4;
        var raw = try w.alloc(u8, (@as(usize, self.h)) * (stride + 1));
        defer w.free(raw);
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            const dst = @as(usize, y) * (stride + 1);
            raw[dst] = 0;
            @memcpy(raw[dst + 1 .. dst + 1 + stride], self.px[@as(usize, y) * stride ..][0..stride]);
        }

        const idat = try zlibStored(w, raw);
        defer w.free(idat);
        try writeChunk(w, &out, "IDAT", idat);
        try writeChunk(w, &out, "IEND", &.{});

        return out.toOwnedSlice(w);
    }

    fn writeChunk(gpa: Allocator, out: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, tag);
        try out.appendSlice(gpa, data);

        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(data);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
        try out.appendSlice(gpa, &crc_bytes);
    }

    /// zlib stream using stored (uncompressed) deflate blocks — no compressor
    /// dependency, valid PNG output.
    fn zlibStored(gpa: Allocator, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, &.{ 0x78, 0x01 });

        var off: usize = 0;
        while (true) {
            const chunk = @min(data.len - off, 65535);
            const is_final = off + chunk == data.len;
            try out.append(gpa, if (is_final) 0x01 else 0x00);
            var lens: [4]u8 = undefined;
            std.mem.writeInt(u16, lens[0..2], @intCast(chunk), .little);
            std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(chunk)), .little);
            try out.appendSlice(gpa, &lens);
            try out.appendSlice(gpa, data[off .. off + chunk]);
            off += chunk;
            if (is_final) break;
        }

        var adler_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &adler_bytes, std.hash.Adler32.hash(data), .big);
        try out.appendSlice(gpa, &adler_bytes);

        return out.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------------
// the rasterizer, under test instead of under eyeball
// ---------------------------------------------------------------------------

const testing = std.testing;

test "three disjoint squares stay disjoint" {
    // The filler closes a polygon back to its first point. While every subpath
    // shared one point list, that closing edge ran from one SQUARE's corner to
    // the NEXT square's corner -- an edge nobody drew, filled as though it were
    // real. With two closed subpaths the join and the list's modulo wrap are the
    // same segment in opposite directions and cancel, so the donut case looks
    // perfect; with three they form a triangle and the fill spills across the
    // whole element. Icons are multi-subpath shapes, so this was the difference
    // between a glyph and a smear.
    const gpa = testing.allocator;
    const ops = [_]elmz.PathOp{
        .move, .line, .line, .line, .close,
        .move, .line, .line, .line, .close,
        .move, .line, .line, .line, .close,
    };
    const pts = [_][2]f32{
        .{ 2, 2 },  .{ 9, 2 },  .{ 9, 9 },  .{ 2, 9 },
        .{ 22, 2 }, .{ 29, 2 }, .{ 29, 9 }, .{ 22, 9 },
        .{ 2, 22 }, .{ 9, 22 }, .{ 9, 29 }, .{ 2, 29 },
    };
    var c = try testCanvas(gpa, 32, 32);
    defer c.deinit();
    c.pathClip(0, 0, .{ .ops = &ops, .points = &pts, .rule = .evenodd }, .{ .solid = .{ .r = 255, .g = 255, .b = 255 } }, elmz.Rect.unbounded);

    var inside: usize = 0;
    var outside: usize = 0;
    for (0..32) |y| {
        for (0..32) |x| {
            const lit = c.px[(y * 32 + x) * 4] > 127;
            const b1 = x >= 2 and x < 9 and y >= 2 and y < 9;
            const b2 = x >= 22 and x < 29 and y >= 2 and y < 9;
            const b3 = x >= 2 and x < 9 and y >= 22 and y < 29;
            if (!lit) continue;
            if (b1 or b2 or b3) inside += 1 else outside += 1;
        }
    }
    // Three 7x7 squares, every pixel of each, and not one pixel anywhere else.
    try testing.expectEqual(@as(usize, 147), inside);
    try testing.expectEqual(@as(usize, 0), outside);

    // An UNCLOSED subpath is legal input and used to wedge even with two of
    // them: the join ran from the open subpath's last point diagonally into the
    // next one's first. `M2 2 L22 2 L22 22 L2 22` has no `Z`.
    const ops2 = [_]elmz.PathOp{ .move, .line, .line, .line, .move, .line, .line, .line, .close };
    const pts2 = [_][2]f32{
        .{ 2, 2 },   .{ 22, 2 },  .{ 22, 22 }, .{ 2, 22 },
        .{ 12, 12 }, .{ 18, 12 }, .{ 18, 18 }, .{ 12, 18 },
    };
    var d = try testCanvas(gpa, 24, 24);
    defer d.deinit();
    d.pathClip(0, 0, .{ .ops = &ops2, .points = &pts2, .rule = .evenodd }, .{ .solid = .{ .r = 255, .g = 255, .b = 255 } }, elmz.Rect.unbounded);
    // Every row above the inner square is solid across the outer one; the wedge
    // cut a diagonal notch out of exactly these.
    for (3..11) |y| {
        for (3..21) |x| {
            try testing.expect(d.px[(y * 24 + x) * 4] > 127);
        }
    }
}

test "a quad covers exactly the pixels it names and nothing else" {
    var c = try testCanvas(testing.allocator, 20, 20);
    defer c.deinit();

    c.fillRect(.{ .x = 5, .y = 5, .w = 10, .h = 10 }, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });

    var lit: usize = 0;
    for (0..20) |y| for (0..20) |x| {
        const i = (y * 20 + x) * 4;
        if (c.px[i] != 0) lit += 1;
    };
    try testing.expectEqual(@as(usize, 100), lit);
    // and it is the right 100: corners in, neighbours out
    const at = struct {
        fn f(px: []const u8, x: usize, y: usize) u8 {
            return px[(y * 20 + x) * 4];
        }
    }.f;
    try testing.expectEqual(@as(u8, 255), at(c.px, 5, 5));
    try testing.expectEqual(@as(u8, 255), at(c.px, 14, 14));
    try testing.expectEqual(@as(u8, 0), at(c.px, 4, 5));
    try testing.expectEqual(@as(u8, 0), at(c.px, 15, 14));
}

/// Decode a PNG this library wrote -- signature, chunks, IDAT, stored deflate
/// blocks -- and hand back the raw RGBA rows with the filter bytes stripped.
///
/// Deliberately not a general PNG decoder: it asserts the profile we EMIT, so a
/// change to the encoder has to come through here. The stored-block header is
/// checked against its own complement, which is the one part of the zlib stream
/// a writer can get wrong without the bytes changing.
fn decodeStoredPng(gpa: Allocator, png: []const u8) ![]u8 {
    var w: u32 = 0;
    var h: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var i: usize = 8; // signature
    while (i + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[i..][0..4], .big);
        const tag = png[i + 4 ..][0..4];
        const data = png[i + 8 ..][0..len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(gpa, data);
        }
        i += 12 + len;
    }
    if (w == 0 or h == 0) return error.MissingHeader;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var z: usize = 2; // zlib header
    while (true) {
        if (z + 5 > idat.items.len) return error.TruncatedDeflate;
        const final = (idat.items[z] & 1) == 1;
        const n = std.mem.readInt(u16, idat.items[z + 1 ..][0..2], .little);
        const inv = std.mem.readInt(u16, idat.items[z + 3 ..][0..2], .little);
        if (inv != ~n) return error.BadDeflateLength;
        try raw.appendSlice(gpa, idat.items[z + 5 ..][0..n]);
        z += 5 + n;
        if (final) break;
    }

    const cols: usize = w;
    const rows: usize = h;
    const px = try gpa.alloc(u8, cols * rows * 4);
    errdefer gpa.free(px);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const row = raw.items[y * (1 + cols * 4) ..][0..(1 + cols * 4)];
        if (row[0] != 0) return error.UnsupportedFilter; // we always write 0
        @memcpy(px[y * cols * 4 ..][0..(cols * 4)], row[1..]);
    }
    return px;
}

test "a quad larger than the canvas is clipped, not corrupting" {
    var c = try testCanvas(testing.allocator, 8, 8);
    defer c.deinit();
    c.fillRect(.{ .x = -50, .y = -50, .w = 500, .h = 500 }, .{ .solid = .{ .r = 9, .g = 9, .b = 9, .a = 255 } });
    var i: usize = 0;
    while (i < c.px.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 9), c.px[i]);
        try testing.expectEqual(@as(u8, 9), c.px[i + 2]);
        // Alpha is NOT untouched: an opaque quad makes the canvas opaque. This
        // assertion used to read 0, which recorded the bug -- a frame painted
        // entirely with opaque colours exported as a fully transparent PNG.
        try testing.expectEqual(@as(u8, 255), c.px[i + 3]);
    }
}

test "text is really antialiased and its measure is not a guess" {
    var c = try testCanvas(testing.allocator, 200, 40);
    defer c.deinit();
    const any = withFace(&c) orelse return;
    defer testing.allocator.free(any);
    c.drawText(2, 2, 20, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } }, "Hamburgefonstiv");

    var seen = std.AutoHashMap(u8, void).init(testing.allocator);
    defer seen.deinit();
    for (c.px) |b| try seen.put(b, {});

    // A bitmap font at integer scale yields 2 levels (0 and ink). Coverage
    // rasterisation yields a spread; if this drops to 2, the TTF path is dead.
    try testing.expect(seen.count() > 20);

    const m = c.renderer().measureText("Hamburgefonstiv", 20);
    try testing.expect(m.width > 100 and m.width < 200);
    try testing.expect(m.height >= 20);
}

test "utf-8 is decoded, not measured as bytes" {
    const any = testing_font.fontWith(testing.allocator, std.testing.io, &.{ '日', '本' }) orelse return;
    defer testing.allocator.free(any);
    const face = Face.init(any);
    const one = face.measure("日", 24);
    const three = face.measure("日本語", 24);
    try testing.expect(one.width > 8);
    // three copies of one glyph == one glyph measured three times
    try testing.expectApproxEqAbs(one.width * 3, three.width, 0.01);
    // and nothing like the 9 bytes it occupies
    try testing.expect(@abs(three.width - one.width * 9) > 1);
    // accented latin too: 'é' is two bytes, one glyph
    try testing.expectApproxEqAbs(
        face.measure("e", 20).width,
        face.measure("é", 20).width,
        0.01,
    );
}

test "wrapping breaks at spaces and loses nothing" {
    var buf: [8][]const u8 = undefined;
    const text = "the quick brown fox jumps";
    const n = testing_font.get().wrapLines(text, 14, 60, &buf);
    try testing.expect(n >= 2);

    var joined: [64]u8 = undefined;
    var len: usize = 0;
    for (buf[0..n]) |line| {
        try testing.expect(testing_font.get().measure(line, 14).width <= 60.5);
        if (len > 0) {
            joined[len] = ' ';
            len += 1;
        }
        @memcpy(joined[len..][0..line.len], line);
        len += line.len;
    }
    try testing.expectEqualStrings(text, joined[0..len]);
}

test "a single overlong word makes progress instead of looping" {
    var buf: [4][]const u8 = undefined;
    const n = testing_font.get().wrapLines("antidisestablishmentarianism", 14, 40, &buf);
    try testing.expect(n >= 1 and n <= 4);
}

test "a wider budget produces fewer lines" {
    var a: [16][]const u8 = undefined;
    var b: [16][]const u8 = undefined;
    const text = "alpha beta gamma delta epsilon zeta";
    // Budgets DERIVED from the face's own measurement: a pixel constant that
    // fits this string in one line for DejaVu does not fit it for the bitmap
    // face, and a test about wrapping should not be a test about a typeface.
    const full = testing_font.get().measure(text, 12).width;
    const narrow = testing_font.get().wrapLines(text, 12, full / 2, &a);
    const wide = testing_font.get().wrapLines(text, 12, full + 10, &b);
    try testing.expect(narrow > wide);
    try testing.expectEqual(@as(usize, 1), wide);
}

test "line height accounts for the font's line gap" {
    const any = testing_font.anySystemFont(testing.allocator, std.testing.io) orelse return;
    defer testing.allocator.free(any);
    const m = Face.init(any).measure("Ag", 20);
    // DejaVu declares a zero line gap, so spacing == height here. The field
    // exists because that is a property of the font, not a constant.
    try testing.expect(m.line_height >= m.height);
    try testing.expect(m.ascent > 0);
    try testing.expect(m.descent < 0);
}

// ---------------------------------------------------------------------------
// gradients: the numbers, not the vibes
// ---------------------------------------------------------------------------

fn chanAt(px: []const u8, w: u32, x: usize, y: usize) u8 {
    return px[(y * @as(usize, w) + x) * 4];
}

test "a vertical gradient ramps top to bottom and is constant across each row" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 40, 100);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 }); // green: anything unpainted shows up
    c.fillRect(.{ .x = 0, .y = 0, .w = 40, .h = 100 }, elmz.Fill.vgrad(
        elmz.Color.rgbHex(0x000000),
        elmz.Color.rgbHex(0xffffff),
    ));
    try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 0))), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 50))), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(chanAt(c.px, c.w, 20, 99))), 3);
    // the per-row fast path is only correct if the colour really is row-constant
    try std.testing.expectEqual(chanAt(c.px, c.w, 1, 50), chanAt(c.px, c.w, 38, 50));
}

test "a horizontal gradient varies by column and not by row" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 100, 10);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 });
    c.fillRect(.{ .x = 0, .y = 0, .w = 100, .h = 10 }, elmz.Fill.hgrad(
        elmz.Color.rgbHex(0x000000),
        elmz.Color.rgbHex(0xffffff),
    ));
    try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(chanAt(c.px, c.w, 0, 5))), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(chanAt(c.px, c.w, 50, 5))), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 255), @as(f32, @floatFromInt(chanAt(c.px, c.w, 99, 5))), 3);
    try std.testing.expectEqual(chanAt(c.px, c.w, 50, 1), chanAt(c.px, c.w, 50, 8));
}

test "every fill kind packs alpha, so an opaque gradient cannot export as a hole" {
    // `blendPixel` writes alpha for an opaque source and its comment says why:
    // src-over onto a cleared canvas leaves the destination at 0, so an opaque
    // frame would export as a fully TRANSPARENT png. The gradient writers each
    // carried their own copy of that opaque branch and three of them dropped
    // the fourth byte, while `encodePng` emits colour type 6 -- so an opaque
    // gradient stored correct RGB at alpha 0 and the picture went out with a
    // hole in it. Invisible on screen (src-over never reads the destination's
    // alpha) and invisible to a pinned png (a pin records what was written).
    const a = elmz.Color{ .r = 255, .g = 0, .b = 0 };
    const b = elmz.Color{ .r = 0, .g = 128, .b = 255 };
    const c = elmz.Color{ .r = 12, .g = 200, .b = 40 };
    // Three opaque stops is the case that bypasses `rampRow` (which is only for
    // two) and lands in the general per-pixel loop, so both paths are covered.
    const three: elmz.Stops = .{ .colors = .{ a, b, c, c }, .n = 3 };
    const fills = [_]elmz.Fill{
        .{ .solid = a },
        elmz.Fill.vgrad(a, b),
        elmz.Fill.hgrad(a, b),
        elmz.Fill.diag(a, b),
        .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 }, .stops = three } },
        .{ .radial = .{ .stops = elmz.Stops.two(a, b) } },
    };
    for (fills) |f| {
        var cv = try testCanvas(std.testing.allocator, 16, 16);
        defer cv.deinit();
        cv.fillRect(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, f);
        var k: usize = 0;
        while (k < 16 * 16) : (k += 1) {
            const al = cv.px[k * 4 + 3];
            if (al != 255) {
                // No print: see the note in the blend test -- stderr fails the
                // build step, and the assertion reports the value it found.
                try std.testing.expectEqual(@as(u8, 255), al);
            }
        }
    }
}

test "coverage and glyphs composite alpha, so text is not a hole in the png" {
    // The fill writers above are not the only paths that produce colour. A
    // rounded rect, a glyph and a translucent quad all go through a COVERAGE
    // blend, and two of those blends left the destination alpha untouched --
    // one of them with a doc comment blessing the choice ("the destination
    // alpha is left alone"). On a cleared canvas that is correct colour at
    // alpha 0, which `encodePng` writes out as a hole; and the two text paths
    // (real face, built-in face) did not even agree with each other.
    const gpa = std.testing.allocator;
    const white = elmz.Color{ .r = 255, .g = 255, .b = 255 };

    // Rounded rect: every pixel of it is coverage-blended, so this is the
    // whole-element case rather than an edge case.
    var c = try testCanvas(gpa, 16, 16);
    defer c.deinit();
    c.roundRect(.{ .x = 2, .y = 2, .w = 12, .h = 12 }, 4, .{ .solid = white }, false);
    try std.testing.expectEqual(@as(u8, 255), c.px[(8 * 16 + 8) * 4 + 3]);

    // Text: the real-face path blends inside cedar, the built-in path inside
    // this file. Both must leave every painted pixel with alpha.
    var t = try testCanvas(gpa, 64, 32);
    defer t.deinit();
    t.drawText(1, 2, 20, .{ .solid = white }, "H");
    var painted: usize = 0;
    var max_a: u8 = 0;
    for (0..64 * 32) |k| {
        if (t.px[k * 4] == 0 and t.px[k * 4 + 1] == 0 and t.px[k * 4 + 2] == 0) continue;
        painted += 1;
        max_a = @max(max_a, t.px[k * 4 + 3]);
        try std.testing.expect(t.px[k * 4 + 3] != 0);
    }
    try std.testing.expect(painted > 20);
    try std.testing.expectEqual(@as(u8, 255), max_a);

    // And the common case is untouched: over an opaque backdrop, 255 stays 255
    // even for a half-transparent source.
    c.fillRect(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, .{ .solid = elmz.Color.rgbHex(0x102030) });
    c.roundRect(.{ .x = 2, .y = 2, .w = 12, .h = 12 }, 4, .{ .solid = .{ .r = 255, .g = 0, .b = 0, .a = 128 } }, false);
    try std.testing.expectEqual(@as(u8, 255), c.px[(8 * 16 + 8) * 4 + 3]);
}

test "a radial fill is brightest at the centre and falls off outward" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 80, 80);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 255, .b = 0 });
    c.fillRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 }, elmz.Fill.radialFill(
        elmz.Color.rgbHex(0xffffff),
        elmz.Color.rgbHex(0x000000),
    ));
    const centre = chanAt(c.px, c.w, 40, 40);
    const edge = chanAt(c.px, c.w, 0, 0);
    try std.testing.expect(centre > 200);
    try std.testing.expect(edge < 60);
}

test "a gradient BORDER ramps around the outline and leaves the interior alone" {
    const gpa = std.testing.allocator;
    const bg = elmz.Color.rgbHex(0x102030);
    for ([_]f32{ 0, 14 }) |radius| {
        var c = try testCanvas(gpa, 60, 60);
        defer c.deinit();
        c.clear(bg);
        c.roundRectClip(.{ .x = 10, .y = 10, .w = 40, .h = 40 }, radius, elmz.Fill.vgrad(
            elmz.Color.rgbHex(0xff0000),
            elmz.Color.rgbHex(0x0000ff),
        ), true, elmz.Rect.unbounded);
        // top edge is the ramp's start, bottom edge its end
        const top = c.px[((10 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        const bot = c.px[((49 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        try std.testing.expect(top[0] > 150 and top[2] < 100);
        try std.testing.expect(bot[2] > 150 and bot[0] < 100);
        // interior untouched: a stroke must not fill the shape
        const mid = c.px[((30 * @as(usize, c.w)) + 30) * 4 ..][0..3];
        try std.testing.expectEqual(bg.r, mid[0]);
        try std.testing.expectEqual(bg.g, mid[1]);
        try std.testing.expectEqual(bg.b, mid[2]);
    }
}

test "text takes a gradient fill, not just a solid colour" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 240, 48);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 0, .b = 0 });
    c.drawText(2, 2, 30, elmz.Fill.hgrad(
        elmz.Color.rgbHex(0xff0000),
        elmz.Color.rgbHex(0x0000ff),
    ), "MMMMMMMM");

    // Inked span, so the test follows the glyphs instead of assuming where
    // they landed.
    var first: ?usize = null;
    var last: usize = 0;
    var inked: usize = 0;
    var x: usize = 0;
    while (x < c.w) : (x += 1) {
        var y: usize = 0;
        while (y < c.h) : (y += 1) {
            const p = c.px[(y * @as(usize, c.w) + x) * 4 ..][0..3];
            if (p[0] > 40 or p[2] > 40) {
                inked += 1;
                if (first == null) first = x;
                last = x;
            }
        }
    }
    try std.testing.expect(inked > 200);

    const f = first.?;
    const span = last - f;
    const third = @max(@as(usize, 1), span / 3);

    // Means, not extremes: the ramp's endpoints are pure red and pure blue, so
    // the MAX of each channel is ~255 at both ends and compares nothing.
    var lr: usize = 0;
    var lb: usize = 0;
    var ln: usize = 0;
    var rr: usize = 0;
    var rb: usize = 0;
    var rn: usize = 0;
    x = f;
    while (x <= last) : (x += 1) {
        var y: usize = 0;
        while (y < c.h) : (y += 1) {
            const p = c.px[(y * @as(usize, c.w) + x) * 4 ..][0..3];
            if (p[0] <= 40 and p[2] <= 40) continue; // background
            if (x < f + third) {
                lr += p[0];
                lb += p[2];
                ln += 1;
            } else if (x > last - third) {
                rr += p[0];
                rb += p[2];
                rn += 1;
            }
        }
    }
    try std.testing.expect(ln > 0 and rn > 0);
    const left_red = lr / ln;
    const right_red = rr / rn;
    const left_blue = lb / ln;
    const right_blue = rb / rn;
    // The ramp must actually run ACROSS the run, not restart per glyph.
    try std.testing.expect(left_red > right_red + 20);
    try std.testing.expect(right_blue > left_blue + 20);
}

test "a blit composites by source alpha instead of stamping it" {
    const gpa = std.testing.allocator;
    var dst = try testCanvas(gpa, 4, 1);
    defer dst.deinit();
    dst.clear(.{ .r = 255, .g = 255, .b = 255 });

    var src = try testCanvas(gpa, 4, 1);
    defer src.deinit();
    src.clear(.{ .r = 0, .g = 0, .b = 0 });
    // 0: half-alpha black -- must land halfway between white and black
    src.px[0] = 0;
    src.px[1] = 0;
    src.px[2] = 0;
    src.px[3] = 128;
    // 1: fully transparent, loud colour -- must not touch the destination
    src.px[4] = 255;
    src.px[5] = 0;
    src.px[6] = 255;
    src.px[7] = 0;
    // 2: opaque red -- must be an exact copy
    src.px[8] = 255;
    src.px[9] = 0;
    src.px[10] = 0;
    src.px[11] = 255;

    dst.blitFrom(&src, .{ 0, 0 });

    // 128/255 of black over white, summed in light. Written as the value the
    // transfer produces rather than a magic number, because what is being
    // asserted is "the alpha was honoured", not "the byte is 126" -- 126 was
    // the encoded-space answer and it is the wrong answer.
    try std.testing.expectEqual(gamma.encode(1.0 - 128.0 / 255.0), dst.px[0]);
    try std.testing.expectEqual(@as(u8, 255), dst.px[3]);
    // invisible source pixels leave the destination pristine
    try std.testing.expectEqual(@as(u8, 255), dst.px[4]);
    try std.testing.expectEqual(@as(u8, 255), dst.px[5]);
    try std.testing.expectEqual(@as(u8, 255), dst.px[6]);
    // opaque source pixels copy exactly
    try std.testing.expectEqual(@as(u8, 255), dst.px[8]);
    try std.testing.expectEqual(@as(u8, 0), dst.px[9]);
}

test "a blitted pixel and a painted pixel of the same alpha agree" {
    const gpa = std.testing.allocator;
    const half = elmz.Color{ .r = 0, .g = 0, .b = 0, .a = 128 };

    // painted: the normal quad path
    var painted = try testCanvas(gpa, 1, 1);
    defer painted.deinit();
    painted.clear(.{ .r = 255, .g = 255, .b = 255 });
    painted.blendPixel(0, 0, half);

    // blitted: a one-pixel canvas with the same colour composited in
    var blitted = try testCanvas(gpa, 1, 1);
    defer blitted.deinit();
    blitted.clear(.{ .r = 255, .g = 255, .b = 255 });

    var src = try testCanvas(gpa, 1, 1);
    defer src.deinit();
    src.px[0] = half.r;
    src.px[1] = half.g;
    src.px[2] = half.b;
    src.px[3] = half.a;
    blitted.blitFrom(&src, .{ 0, 0 });

    try std.testing.expectEqualSlices(u8, painted.px, blitted.px);
}

test "an opaque blit is still a byte-exact copy" {
    const gpa = std.testing.allocator;
    var dst = try testCanvas(gpa, 3, 2);
    defer dst.deinit();
    dst.clear(.{ .r = 7, .g = 8, .b = 9 });

    var src = try testCanvas(gpa, 3, 2);
    defer src.deinit();
    src.clear(.{ .r = 200, .g = 100, .b = 50 });
    // a non-uniform second row, so a row-offset bug cannot pass
    const row1: usize = @as(usize, src.w) * 4;
    src.px[row1 + 0] = 1;
    src.px[row1 + 5] = 2;

    dst.blitFrom(&src, .{ 0, 0 });
    try std.testing.expectEqualSlices(u8, src.px, dst.px);
}

test "compositing onto a transparent canvas keeps the colour, not black" {
    const gpa = std.testing.allocator;
    // init() memsets to zero, so this destination starts at alpha 0 -- the case
    // a blend that forgets to normalise by the OUTPUT alpha turns into black.
    var dst = try testCanvas(gpa, 1, 1);
    defer dst.deinit();

    var src = try testCanvas(gpa, 1, 1);
    defer src.deinit();
    src.px[0] = 0;
    src.px[1] = 200;
    src.px[2] = 0;
    src.px[3] = 128;

    dst.blitFrom(&src, .{ 0, 0 });
    try std.testing.expectEqual(@as(u8, 0), dst.px[0]);
    try std.testing.expectEqual(@as(u8, 200), dst.px[1]);
    try std.testing.expectEqual(@as(u8, 128), dst.px[3]);
}

test "a blit clipped by the destination edge drops the rest" {
    const gpa = std.testing.allocator;
    var dst = try testCanvas(gpa, 2, 2);
    defer dst.deinit();
    dst.clear(.{ .r = 0, .g = 0, .b = 0 });

    var src = try testCanvas(gpa, 4, 4);
    defer src.deinit();
    src.clear(.{ .r = 255, .g = 0, .b = 0 });

    dst.blitFrom(&src, .{ 1, 1 });
    // only the source's top-left pixel lands, at the destination's far corner
    try std.testing.expectEqual(@as(u8, 255), dst.px[((1 * 2) + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0), dst.px[0]);

    // an origin outside the destination is a no-op, not a crash
    dst.blitFrom(&src, .{ 9, 9 });
    dst.blitFrom(&src, .{ 2, 0 });
}

test "the default bakes, and an explicit .sdf never touches the cache" {
    var c = try testCanvas(std.testing.allocator, 200, 160);
    defer c.deinit();

    const rect = elmz.Rect{ .x = 60, .y = 50, .w = 80, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const color = elmz.Color{ .r = 255, .g = 200, .b = 0, .a = 220 };
    c.clear(elmz.Color{ .r = 20, .g = 20, .b = 20, .a = 255 });

    // A small blur used to be handed to the distance field, on the argument
    // that baking a mask would cost more than the ramp saved. It does not any
    // more: a template bake is small and independent of the silhouette.
    c.halo(rect, 8, .{ .color = color, .blur = 6, .mode = .glow }, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 1), c.bakes);

    // A different blur is a different stencil, and the second draw of it must
    // find the first rather than bake again. `bakes` is what tells a hit from
    // a re-bake; the entry count alone cannot.
    c.halo(rect, 8, .{ .color = color, .blur = 24, .mode = .glow }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.bakes);
    c.halo(rect, 8, .{ .color = color, .blur = 24, .mode = .glow }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.bakes);

    // ...while an explicit `.sdf` must not consult the cache at all. This is
    // the precedence the switch exists for: the default is not an override.
    //
    // The silhouette here is deliberately DIFFERENT from the ones above. Asking
    // for `.sdf` on the same geometry would find the existing stencil and leave
    // the count unchanged even if the baked path ran -- a cache hit is not
    // evidence about dispatch. A fresh shape is: if `.sdf` fell through to
    // baked, this draw would have to build stencil number three.
    c.halo(elmz.Rect{ .x = 20, .y = 20, .w = 60, .h = 40 }, 8, .{ .color = color, .blur = 24, .mode = .glow, .quality = .sdf }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.bakes);
}

fn darknessIn(c: *Canvas, x0: usize, x1: usize, y0: usize, y1: usize, stride: usize) u64 {
    var sum: u64 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) sum += 255 - c.px[(y * stride + x) * 4];
    }
    return sum;
}

test "a shadow falls on the side away from its light, on both axes" {
    // The vertical axis was the only one ever measured, so a sign error on the
    // horizontal axis would have survived every test in this file. Four angles,
    // each asserted against the documented convention rather than against
    // whatever the code happens to do: clock 0 is a lamp overhead, so the shadow
    // lands BELOW; 90 is a lamp on the right, so it lands LEFT.
    const lights = [_]f32{ 0, 90, 180, 270 };
    inline for (lights, 0..) |deg, k| {
        var c = try testCanvas(std.testing.allocator, 220, 220);
        defer c.deinit();
        c.clear(elmz.Color{ .r = 244, .g = 244, .b = 248, .a = 255 });
        const card = elmz.Rect{ .x = 80, .y = 80, .w = 60, .h = 60 };
        const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 220 };
        c.halo(card, 8, elmz.Halo.shadow(.{ .r = 12, .g = 10, .b = 20, .a = 255 }, deg, 10), clip);
        const above = darknessIn(&c, 90, 130, 50, 79, 220);
        const below = darknessIn(&c, 90, 130, 141, 170, 220);
        const left = darknessIn(&c, 50, 79, 90, 130, 220);
        const right = darknessIn(&c, 141, 170, 90, 130, 220);
        switch (k) {
            0 => try std.testing.expect(below > above),
            1 => try std.testing.expect(left > right),
            2 => try std.testing.expect(above > below),
            else => try std.testing.expect(right > left),
        }
    }
}

test "a light widens the ramp on the side it throws the shadow toward" {
    // Separate from the test above on purpose: there the offset dominates the
    // darkness, so an inverted `lightWidth` would hide behind it. Here the offset
    // is zero and the ONLY asymmetry is the falloff width, which is the thing
    // under test.
    const lights = [_]f32{ 0, 180 };
    inline for (lights, 0..) |deg, k| {
        var c = try testCanvas(std.testing.allocator, 220, 220);
        defer c.deinit();
        c.clear(elmz.Color{ .r = 244, .g = 244, .b = 248, .a = 255 });
        const card = elmz.Rect{ .x = 80, .y = 80, .w = 60, .h = 60 };
        const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 220 };
        c.halo(card, 8, .{
            .color = .{ .r = 12, .g = 10, .b = 20, .a = 255 },
            .blur = 18,
            .spread = 2,
            .mode = .outer_glow,
            .light = deg,
        }, clip);
        // Symmetric bands, no offset: only the ramp width can break the tie.
        const above = darknessIn(&c, 90, 130, 52, 79, 220);
        const below = darknessIn(&c, 90, 130, 141, 168, 220);
        if (k == 0) {
            try std.testing.expect(below > above);
        } else {
            try std.testing.expect(above > below);
        }
    }
}

test "the baked stencil matches the distance field across a sliced glow" {
    // The stretch band has to clear the RAMP, not just the corner arc. It did
    // not, and this test is the one that says so: a large halo repeated a
    // mid-ramp column across its whole face, so baked painted 223 where the
    // distance field drew 202 -- a 21/255 step over the middle of every sliced
    // glow, which is the "baked looks bigger" report.
    var a = try testCanvas(std.testing.allocator, 220, 160);
    defer a.deinit();
    var b = try testCanvas(std.testing.allocator, 220, 160);
    defer b.deinit();
    a.clear(elmz.Color{ .r = 24, .g = 24, .b = 30, .a = 255 });
    b.clear(elmz.Color{ .r = 24, .g = 24, .b = 30, .a = 255 });
    const rect = elmz.Rect{ .x = 60, .y = 50, .w = 100, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 160 };
    const col = elmz.Color{ .r = 255, .g = 200, .b = 0, .a = 220 };
    a.halo(rect, 8, .{ .color = col, .blur = 24, .mode = .glow, .quality = .sdf }, clip);
    b.halo(rect, 8, .{ .color = col, .blur = 24, .mode = .glow, .quality = .baked }, clip);

    // The silhouette must be big enough that a stencil really was used, or this
    // compares the field path to itself.
    try std.testing.expectEqual(@as(i32, 0), b.masks.items[0].sw);
    var worst: u32 = 0;
    var off: usize = 0;
    for (a.px, b.px) |x, y| {
        const d = @abs(@as(i32, x) - @as(i32, y));
        if (d > worst) worst = d;
        if (d > 2) off += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expect(worst <= 2);
}

test "a baked outer rim does not light its own face" {
    // `.glow` and `.outer_glow` are the same ramp; what makes a rim outer is the
    // cut against the element. The stencil had nowhere for that cut, so a baked
    // outer glow painted its inner half over its own face and was simply a glow
    // wearing a different mode name.
    var a = try testCanvas(std.testing.allocator, 200, 140);
    defer a.deinit();
    var b = try testCanvas(std.testing.allocator, 200, 140);
    defer b.deinit();
    const bg = elmz.Color{ .r = 20, .g = 20, .b = 26, .a = 255 };
    a.clear(bg);
    b.clear(bg);
    const rect = elmz.Rect{ .x = 50, .y = 40, .w = 100, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 140 };
    const col = elmz.Color{ .r = 255, .g = 200, .b = 0, .a = 220 };
    a.halo(rect, 8, .{ .color = col, .blur = 20, .mode = .outer_glow, .quality = .sdf }, clip);
    b.halo(rect, 8, .{ .color = col, .blur = 20, .mode = .outer_glow, .quality = .baked }, clip);
    try std.testing.expectEqual(@as(i32, 0), b.masks.items[0].sw);

    // Deep inside the face: untouched, both ways.
    const mid = (80 * 200 + 100) * 4;
    try std.testing.expectEqual(bg.r, b.px[mid]);
    try std.testing.expectEqual(bg.r, a.px[mid]);

    var off: usize = 0;
    for (a.px, b.px) |x, y| {
        const d = @abs(@as(i32, x) - @as(i32, y));
        if (d > 2) off += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), off);
}

test "an offset outer glow takes the field path at both qualities" {
    // NOTE: this is a FALLBACK check, not an agreement check. `geometric_cut`
    // sends any outer rim with an offset or a spread to the distance field, so
    // both canvases below run the same code and identical pixels prove nothing
    // about the stencil. It passed for months while the stencil disagreed with
    // the field by 21/255 -- see the two tests that follow for the real thing.
    var a = try testCanvas(std.testing.allocator, 200, 160);
    defer a.deinit();
    var b = try testCanvas(std.testing.allocator, 200, 160);
    defer b.deinit();
    a.clear(elmz.Color{ .r = 24, .g = 24, .b = 30, .a = 255 });
    b.clear(elmz.Color{ .r = 24, .g = 24, .b = 30, .a = 255 });

    const rect = elmz.Rect{ .x = 60, .y = 50, .w = 80, .h = 60 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const base = elmz.Halo{
        .color = .{ .r = 255, .g = 200, .b = 0, .a = 220 },
        .blur = 20,
        .spread = 2,
        .offset = .{ 0, 6 },
        .mode = .outer_glow,
    };
    a.halo(rect, 10, .{ .color = base.color, .blur = base.blur, .spread = base.spread, .offset = base.offset, .mode = base.mode, .quality = .sdf }, clip);
    b.halo(rect, 10, .{ .color = base.color, .blur = base.blur, .spread = base.spread, .offset = base.offset, .mode = base.mode, .quality = .baked }, clip);

    // Same silhouette, two renderers of it. Quantising coverage to a byte is
    // the only licence to differ, so anything past rounding is a real drift.
    var worst: u32 = 0;
    var off: usize = 0;
    for (a.px, b.px) |x, y| {
        const d = @abs(@as(i32, x) - @as(i32, y));
        if (d > worst) worst = d;
        if (d > 2) off += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expect(worst <= 2);
}
test "a baked inner rim agrees with the field path, boundary rows included" {
    const bg = elmz.Color{ .r = 38, .g = 40, .b = 52, .a = 255 };
    const col = elmz.Color{ .r = 205, .g = 214, .b = 244, .a = 48 };
    const rect = elmz.Rect{ .x = 20, .y = 30, .w = 124, .h = 32 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const W = 200;
    var field = try testCanvas(std.testing.allocator, W, 100);
    defer field.deinit();
    field.clear(bg);
    field.halo(rect, 8, .{ .color = col, .blur = 20, .spread = 2, .mode = .inner_glow, .quality = .sdf }, clip);
    var baked = try testCanvas(std.testing.allocator, W, 100);
    defer baked.deinit();
    baked.clear(bg);
    baked.halo(rect, 8, .{ .color = col, .blur = 20, .spread = 2, .mode = .inner_glow, .quality = .baked }, clip);

    // The FIRST and last row of the face are the ones that matter. The field path
    // tapers the rim over the last 1.5px so the fill owns the outermost pixel; a
    // stencil that skips the taper draws that row at full strength, which is 23
    // levels here -- enough to put back the corner stair the taper removed. Baked
    // is the DEFAULT, so a parity test that only sampled the interior would miss
    // it entirely.
    var worst: i32 = 0;
    var worst_edge: i32 = 0;
    var y: usize = 28;
    while (y < 66) : (y += 1) {
        var x: usize = 20;
        while (x < 146) : (x += 1) {
            const o = (y * W + x) * 4;
            for (0..3) |k| {
                // Coverage, not encoded bytes. Blending is in linear light now,
                // so two paths a code value apart in coverage can sit several
                // apart once re-encoded, and the encoded difference would grade
                // the transfer curve instead of the agreement under test.
                const df: i32 = @intFromFloat(@round(gamma.to_linear[field.px[o + k]] * 255.0));
                const db: i32 = @intFromFloat(@round(gamma.to_linear[baked.px[o + k]] * 255.0));
                const d = df - db;
                const ad = if (d < 0) -d else d;
                worst = @max(worst, ad);
                if (y == 30 or y == 61) worst_edge = @max(worst_edge, ad);
            }
        }
    }
    // Two tolerances, because two different things are being compared. The
    // boundary rows are geometry and must be exact -- that is where the missing
    // taper showed up as 23. The interior carries the POOL, which is baked from
    // the template's half-width (64) rather than the face's (62), so it can be a
    // few levels out. Naming both keeps the guard meaningful instead of loosening
    // one number until it stops catching anything.
    try std.testing.expect(worst_edge <= 2);
    try std.testing.expect(worst <= 10);
}

test "an inner rim is baked once and reused, mode included in the key" {
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 300, .h = 160 };
    var c = try testCanvas(std.testing.allocator, 300, 160);
    defer c.deinit();
    c.clear(elmz.Color{ .r = 38, .g = 40, .b = 52, .a = 255 });
    const h = elmz.Halo{
        .color = elmz.Color{ .r = 205, .g = 214, .b = 244, .a = 48 },
        .blur = 20,
        .spread = 2,
        .mode = .inner_glow,
        .quality = .baked,
    };
    const r = elmz.Rect{ .x = 20, .y = 20, .w = 124, .h = 32 };
    c.halo(r, 8, h, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    const first = c.bakes;

    // Two things at once. The entry must carry its MODE -- `admit` once dropped it,
    // so every entry was stamped `.glow`, no lookup for another mode could ever
    // match, and each frame re-baked. And the second call must hit: a cache that
    // misses silently still draws the right picture, so the bake counter is the
    // only evidence.
    c.halo(r, 8, h, clip);
    c.halo(r, 8, h, clip);
    try std.testing.expectEqual(first, c.bakes);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    try std.testing.expectEqual(elmz.Halo.Mode.inner_glow, c.masks.items[0].mode);
}

test "an inner rim's template follows its aspect bucket, not the bare minimum" {
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 320, .h = 300 };
    var c = try testCanvas(std.testing.allocator, 320, 300);
    defer c.deinit();
    c.clear(elmz.Color{ .r = 38, .g = 40, .b = 52, .a = 255 });
    const h = elmz.Halo{ .color = elmz.Color{ .r = 205, .g = 214, .b = 244, .a = 48 }, .blur = 20, .spread = 2, .mode = .inner_glow, .quality = .baked };

    // 124x32 rounds to aspect 4, so the template is 128 wide. 130x32 lands in the
    // same bucket and must reuse it -- width does not enter the key beyond this.
    c.halo(.{ .x = 10, .y = 10, .w = 124, .h = 32 }, 8, h, clip);
    c.halo(.{ .x = 10, .y = 60, .w = 130, .h = 32 }, 8, h, clip);
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    const tsw0 = c.masks.items[0].sw;
    try std.testing.expect(tsw0 > 65); // wider than the corner bands alone

    // 100x32 rounds to aspect 3 and is a different template.
    c.halo(.{ .x = 10, .y = 120, .w = 100, .h = 32 }, 8, h, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expect(c.masks.items[1].sw != tsw0);
}

test "nine slices: differently sized silhouettes share a single stencil" {
    var c = try testCanvas(std.testing.allocator, 700, 320);
    defer c.deinit();
    c.clear(elmz.Color{ .r = 18, .g = 18, .b = 22, .a = 255 });
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 700, .h = 320 };
    const color = elmz.Color{ .r = 120, .g = 200, .b = 255, .a = 200 };

    // Three widths, one radius and blur. Before slicing these were three
    // stencils, and a view with a hundred glowing rows baked all hundred --
    // every frame, since eight entries cannot hold a hundred sizes.
    // 80 tall, not 50: a band has to clear the ramp as well as the arc, so a
    // silhouette must be at least 2*(grow + blur/2) tall before its corners stop
    // overlapping. At blur 26 that is 54, and 50 was under it -- which is what
    // caught this: three entries appeared because nothing was sliceable.
    const widths = [_]f32{ 120, 260, 420 };
    for (widths, 0..) |w, i| {
        c.halo(.{
            .x = 20,
            .y = 20 + @as(f32, @floatFromInt(i)) * 80,
            .w = w,
            .h = 80,
        }, 8, .{ .color = color, .blur = 26, .mode = .glow, .quality = .baked }, clip);
    }
    try std.testing.expectEqual(@as(usize, 1), c.masks.items.len);
    try std.testing.expectEqual(@as(i32, 0), c.masks.items[0].sw);

    // A silhouette smaller than two corner bands cannot be sliced -- the
    // corners would overlap -- so it keeps a full bake of its own.
    c.halo(.{ .x = 20, .y = 270, .w = 12, .h = 12 }, 8, .{ .color = color, .blur = 26, .mode = .glow, .quality = .baked }, clip);
    try std.testing.expectEqual(@as(usize, 2), c.masks.items.len);
    try std.testing.expect(c.masks.items[1].sw > 0);
}

test "a stretched stencil still agrees with the distance field when large" {
    var a = try testCanvas(std.testing.allocator, 520, 300);
    defer a.deinit();
    var b = try testCanvas(std.testing.allocator, 520, 300);
    defer b.deinit();
    a.clear(elmz.Color{ .r = 22, .g = 22, .b = 28, .a = 255 });
    b.clear(elmz.Color{ .r = 22, .g = 22, .b = 28, .a = 255 });

    // Long edges, so the middle of each edge is stretched far past the baked
    // corner -- the part of a 9-slice that is actually an approximation.
    const rect = elmz.Rect{ .x = 60, .y = 90, .w = 380, .h = 110 };
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 520, .h = 300 };
    const h = elmz.Halo{
        .color = .{ .r = 255, .g = 190, .b = 90, .a = 210 },
        .blur = 30,
        .spread = 3,
        .offset = .{ 0, 8 },
        .mode = .outer_glow,
    };
    a.halo(rect, 14, .{ .color = h.color, .blur = h.blur, .spread = h.spread, .offset = h.offset, .mode = h.mode, .quality = .sdf }, clip);
    b.halo(rect, 14, .{ .color = h.color, .blur = h.blur, .spread = h.spread, .offset = h.offset, .mode = h.mode, .quality = .baked }, clip);

    var worst: u32 = 0;
    var off: usize = 0;
    for (a.px, b.px) |x, y| {
        const d = @abs(@as(i32, x) - @as(i32, y));
        if (d > worst) worst = d;
        if (d > 2) off += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expect(worst <= 2);
}

fn testPx(c: *Canvas, x: usize, y: usize) [4]u8 {
    const o = (y * c.w + x) * 4;
    return c.px[o..][0..4].*;
}

/// RGB only. A freshly `init`ed canvas starts at alpha 0 and the opaque fast path
/// in `blendPixel` leaves destination alpha alone, which is correct for a canvas
/// that is cleared and painted as a whole -- colour is what these tests are about.
fn testRgb(c: *Canvas, x: usize, y: usize) [3]u8 {
    const p = testPx(c, x, y);
    return .{ p[0], p[1], p[2] };
}

test "the stencil and the distance field put the ramp in the same place" {
    const gpa = std.testing.allocator;

    // Where does coverage cross half, scanning inward from outside the shape?
    // Interpolated between samples, so the answer is not quantised to a pixel.
    const Spot = struct {
        fn cross(c: *Canvas, sx: i32, sy: i32, dx: i32, dy: i32, steps: usize) f32 {
            var prev: f32 = -1;
            var i: usize = 0;
            while (i < steps) : (i += 1) {
                const k: i32 = @intCast(i);
                const x: usize = @intCast(sx + dx * k);
                const y: usize = @intCast(sy + dy * k);
                if (x >= 260 or y >= 200) return -1;
                const v: f32 = @floatFromInt(testRgb(c, x, y)[0]);
                if (v >= 128) {
                    if (prev < 0) return @floatFromInt(i);
                    return @as(f32, @floatFromInt(i - 1)) + (128 - prev) / (v - prev);
                }
                prev = v;
            }
            return -1;
        }
        fn edges(w: f32, h: f32, spread: f32, q: elmz.Halo.Quality) ![4]f32 {
            const clip = elmz.Rect{ .x = 0, .y = 0, .w = 260, .h = 200 };
            const rect = elmz.Rect{ .x = 40, .y = 40, .w = w, .h = h };
            var c = try testCanvas(gpa, 260, 200);
            defer c.deinit();
            const r = c.renderer();
            r.quad(clip, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
            r.halo(rect, 10, .{
                .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
                .blur = 14,
                .spread = spread,
                .mode = .glow,
                .quality = q,
            }, clip);
            const midy: i32 = @intFromFloat(40 + h * 0.5);
            const midx: i32 = @intFromFloat(40 + w * 0.5);
            const rx: i32 = @intFromFloat(40 + w);
            const by: i32 = @intFromFloat(40 + h);
            const l = @This().cross(&c, 10, midy, 1, 0, 45);
            const rr = @This().cross(&c, rx + 30, midy, -1, 0, 45);
            const t = @This().cross(&c, midx, 15, 0, 1, 40);
            const bb = @This().cross(&c, midx, by + 25, 0, -1, 40);
            if (l < 0 or rr < 0 or t < 0 or bb < 0) return error.NoCrossing;
            return .{ 10 + l, @as(f32, @floatFromInt(rx + 30)) - rr, 15 + t, @as(f32, @floatFromInt(by + 25)) - bb };
        }
    };

    // 74x34 is under 2*corner at blur 14 / radius 10, so it takes the whole-mask
    // bake; 120x80 is over it and takes the nine-slice template. A 34px button
    // is what the examples actually draw, so both branches need covering.
    inline for (.{ .{ 74, 34 }, .{ 120, 80 } }) |sz| {
        inline for (.{ 0, 2, 4 }) |sp| {
            const sdf = try Spot.edges(sz[0], sz[1], sp, .sdf);
            const baked = try Spot.edges(sz[0], sz[1], sp, .baked);
            for (sdf, baked) |a, b| {
                // One pixel of slack, on a ramp that spans blur = 14. The
                // measured disagreement is 0.03px -- the coverage byte's own
                // rounding -- so this catches a displaced silhouette while
                // tolerating the quantisation that will never be removed.
                try std.testing.expectApproxEqAbs(a, b, 1.0);
            }
        }
    }
}

test "a wide inner glow keeps the corners it is attached to" {
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const rect = elmz.Rect{ .x = 40, .y = 40, .w = 80, .h = 60 };

    // (42,70) is a pixel inside the left edge at mid-height; (44,44) is 4px in
    // from the top-left corner on the diagonal. A rim light has to be bright at
    // both: it is attached to the shape, and the shape has corners. What the
    // blend changes is further in, where the falloff is decaying -- the outline
    // is no longer legible there and the pool rounds off.
    inline for (.{ 30, 14 }) |blur| {
        var c = try testCanvas(gpa, 200, 160);
        defer c.deinit();
        const r = c.renderer();
        r.quad(clip, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
        r.halo(rect, 8, .{
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .blur = blur,
            .mode = .inner_glow,
            .quality = .sdf,
        }, clip);

        const edge: f32 = @floatFromInt(testRgb(&c, 42, 70)[0]);
        const corner: f32 = @floatFromInt(testRgb(&c, 44, 44)[0]);
        const middle: f32 = @floatFromInt(testRgb(&c, 80, 70)[0]);

        // The rim is on the corner at every width. Uniformly blending the metric
        // (the first attempt) drove this to zero and hollowed the button out.
        try std.testing.expect(corner > 150);
        // ...and it decays: this is a rim, not a wash.
        try std.testing.expect(edge > middle);
    }
}

test "an outer rim is feathered where it meets the element" {
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const rect = elmz.Rect{ .x = 40, .y = 40, .w = 80, .h = 60 };

    var c = try testCanvas(gpa, 200, 160);
    defer c.deinit();
    const r = c.renderer();
    r.quad(rect, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
    r.halo(rect, 8, .{
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .blur = 24,
        .spread = 3,
        .mode = .outer_glow,
        .quality = .sdf,
    }, clip);

    // A binary inside/outside cut gives one step from fill to rim at the shape's
    // boundary -- the worst place for it is the rounded corner, where the fill was
    // antialiased and the rim was not. One pixel outside the corner is partially
    // covered by the element, so the rim has to be partial there too.
    const just_outside: f32 = @floatFromInt(testRgb(&c, 39, 39)[0]);
    const clear_of_it: f32 = @floatFromInt(testRgb(&c, 30, 30)[0]);
    try std.testing.expect(just_outside > clear_of_it);
    try std.testing.expect(just_outside < 255);
}

test "an inner glow drops fast off the edge and then converges" {
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 160 };
    const rect = elmz.Rect{ .x = 40, .y = 40, .w = 80, .h = 60 };

    inline for (.{ .sdf, .baked }) |q| {
        var c = try testCanvas(gpa, 200, 160);
        defer c.deinit();
        const r = c.renderer();
        r.quad(clip, .{ .solid = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }, clip);
        // Opaque white on black, so the red channel IS the coverage.
        r.halo(rect, 8, .{
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .blur = 14,
            .mode = .inner_glow,
            .quality = q,
        }, clip);

        const y: usize = 70; // mid-height, clear of the corners
        // Read coverage, not the byte: the byte is now the transfer curve
        // applied to the coverage, and every number below is coverage on a
        // 0..255 scale. Encoding 0.797 gives 231, which is exactly what the
        // raw channel says -- the two views agree once one of them is decoded.
        const edge: f32 = gamma.to_linear[testRgb(&c, 41, y)[0]] * 255.0;
        const half: f32 = gamma.to_linear[testRgb(&c, 47, y)[0]] * 255.0;
        const deep: f32 = gamma.to_linear[testRgb(&c, 53, y)[0]] * 255.0;
        const gone: f32 = gamma.to_linear[testRgb(&c, 55, y)[0]] * 255.0;

        // Full at the silhouette: d = -1.5, u = 0.107, (1-u)^2 = 0.797.
        try std.testing.expectApproxEqAbs(@as(f32, 203), edge, 12);
        // Halfway in it is nearly spent -- 0.216, not the 0.464 a linear ramp gives.
        // This is the assertion that distinguishes "drops fast" from "drops evenly".
        try std.testing.expectApproxEqAbs(@as(f32, 55), half, 12);
        // And it converges rather than stopping: still a trace, close to nothing.
        try std.testing.expect(deep < 6);
        try std.testing.expect(gone < 2);
        // Monotone: no ring, no plateau.
        try std.testing.expect(edge > half and half > deep and deep >= gone);
    }
}

test "a cast shadow fills the strip under its element and never tints the face" {
    // The strip between the element's edge and the offset silhouette is the whole
    // point: cut against the SHAPE instead of the element and that strip is left
    // as bare backdrop, so the shadow reads as a detached smear a few pixels below
    // the card rather than as the card's shadow.
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 220, 180);
    defer c.deinit();
    const r = c.renderer();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 180 };
    const bg = elmz.Color{ .r = 30, .g = 30, .b = 46, .a = 255 };
    const panel = elmz.Color{ .r = 49, .g = 50, .b = 68, .a = 255 };
    r.quad(clip, .{ .solid = bg }, clip);

    const rect = elmz.Rect{ .x = 60, .y = 40, .w = 100, .h = 70 };
    r.quad(rect, .{ .solid = panel }, clip);
    r.halo(rect, 0, .{
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 200 },
        .blur = 24,
        .spread = 4,
        .offset = .{ 0, 12 },
        .light = 0, // clock 0 is overhead, so the shadow is thrown downward
        .mode = .outer_glow,
    }, clip);

    // 1. The face is untouched. An outer rim is cut against the element, so a
    //    displaced silhouette cannot smear across what it is cast by.
    try std.testing.expectEqual([3]u8{ 49, 50, 68 }, testRgb(&c, 110, 75));

    // 2. The strip under the element is shadowed, not bare backdrop. y = 116 is
    //    6px below the element's bottom edge and inside the offset silhouette.
    const strip = testPx(&c, 110, 116);
    try std.testing.expect(strip[0] < 20);

    // 3. The lit side is not darkened as much as the cast side, at the same
    //    distance from the element -- that is what the light angle buys.
    const above = testPx(&c, 110, 34);
    const below = testPx(&c, 110, 128);
    try std.testing.expect(above[0] > below[0]);

    // 4. Far outside the ring, nothing at all.
    try std.testing.expectEqual([3]u8{ 30, 30, 46 }, testRgb(&c, 8, 8));
}

test "a frost blurs what is behind it and leaves everything else alone" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 200, 140);
    defer c.deinit();
    const r = c.renderer();
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 200, .h = 140 };

    // Hard 3px black/white stripes: a blur that does nothing is obvious, and a
    // blur that samples outside its rect darkens the edges as well.
    var x: usize = 0;
    while (x < 200) : (x += 1) {
        const on = (x / 3) % 2 == 0;
        const v: u8 = if (on) 0 else 255;
        r.quad(.{ .x = @floatFromInt(x), .y = 0, .w = 1, .h = 140 }, .{ .solid = .{ .r = v, .g = v, .b = v, .a = 255 } }, clip);
    }

    const outside_before = testRgb(&c, 20, 70);

    r.frost(.{ .x = 50, .y = 40, .w = 100, .h = 60 }, 0, 8, clip);

    // Inside: the extremes are pulled toward the mean in both directions, which is
    // what a blur is. A no-op frost leaves these at 0 and 255.
    const after_a: i32 = testRgb(&c, 100, 70)[0];
    const after_b: i32 = testRgb(&c, 103, 70)[0];
    // One of the pair was a white stripe and one a black stripe; a blur pulls both
    // toward the mean, so assert on the GAP rather than on each value.
    try std.testing.expect(@max(after_a, after_b) - @min(after_a, after_b) < 90);

    // Outside the rect: byte-identical. This is the check a missing clip fails.
    try std.testing.expectEqual(outside_before, testRgb(&c, 20, 70));

    // No dark rim at the rect's own border: the corner pixel of the frosted area is
    // a blend of real colours, not the zero-padding of a buffer that ran out.
    const edge = testRgb(&c, 51, 41);
    try std.testing.expect(edge[0] > 20 and edge[0] < 235);
}

test "a light source throws the ramp further on the away side" {
    // The asymmetry is the entire reason `light` exists: an offset alone displaces
    // the silhouette but leaves the falloff identical on every edge, which reads as
    // a copy rather than as cast light.
    const gpa = std.testing.allocator;
    const rect = elmz.Rect{ .x = 60, .y = 40, .w = 100, .h = 70 };

    const Case = struct {
        fn bands(light: ?f32, above: *usize, below: *usize) !void {
            var c = try testCanvas(gpa, 220, 180);
            defer c.deinit();
            const r = c.renderer();
            const clip = elmz.Rect{ .x = 0, .y = 0, .w = 220, .h = 180 };
            const bg = elmz.Color{ .r = 30, .g = 30, .b = 46, .a = 255 };
            r.quad(clip, .{ .solid = bg }, clip);
            r.quad(rect, .{ .solid = .{ .r = 49, .g = 50, .b = 68, .a = 255 } }, clip);
            r.halo(rect, 0, .{
                .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                .blur = 24,
                .offset = .{ 0, 8 },
                .light = light,
                .mode = .outer_glow,
            }, clip);

            // `a` holds the FARTHEST dark row above the element, so the extent is
            // how far the ramp reached -- not the last dark row, which is always the
            // one next to the element and would report the same number every time.
            var a: usize = 40;
            var y: usize = 0;
            while (y < 40) : (y += 1) {
                if (testRgb(&c, 110, y)[0] < 29 and y < a) a = y;
            }
            var b: usize = 110;
            y = 111;
            while (y < 180) : (y += 1) {
                if (testRgb(&c, 110, y)[0] < 29) b = y;
            }
            above.* = 40 - a;
            below.* = b - 110;
        }
    };

    var wa: usize = 0;
    var wb: usize = 0;
    try Case.bands(0, &wa, &wb);
    var oa: usize = 0;
    var ob: usize = 0;
    try Case.bands(null, &oa, &ob);

    // Compared against the SAME offset with no light, because the offset alone
    // already lengthens the band it points at. Light must move each side in its own
    // direction: longer away from the source, shorter toward it.
    try std.testing.expect(wb > ob);
    try std.testing.expect(wa < oa);
    try std.testing.expect(wb > wa);
}

test "a frame painted with opaque colours exports an opaque alpha channel" {
    // The failure this catches is invisible to every other test: RGB is correct,
    // and the PNG is a fully transparent image that renders black everywhere.
    // src-over onto a cleared canvas leaves the destination alpha at 0 unless the
    // opaque path writes it, so a frame made only of opaque fills exports as
    // nothing at all.
    const gpa = std.testing.allocator;
    const clip = elmz.Rect{ .x = 0, .y = 0, .w = 32, .h = 24 };
    var c = try testCanvas(gpa, 32, 24);
    defer c.deinit();
    const r = c.renderer();

    r.quad(clip, .{ .solid = elmz.Color.rgbHex(0x1e1e2e) }, clip);
    // Both opaque paths: the row fill above, a per-pixel blend here.
    r.halo(.{ .x = 8, .y = 6, .w = 12, .h = 10 }, 3, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .blur = 2, .mode = .glow }, clip);

    for (0..24) |y| {
        for (0..32) |x| {
            const a = c.px[(y * 32 + x) * 4 + 3];
            try std.testing.expectEqual(@as(u8, 255), a);
        }
    }

    // A translucent fill over the opaque result must not un-opaque it: src-over
    // onto alpha 255 stays 255.
    r.quad(clip, .{ .solid = .{ .r = 255, .g = 0, .b = 0, .a = 128 } }, clip);
    try std.testing.expectEqual(@as(u8, 255), c.px[(5 * 32 + 5) * 4 + 3]);
}

// The blind spot, stated as a test. An opaque frame used to export with alpha 0
// on every pixel -- correct RGB, invisible in every viewer -- because the fast
// paths wrote r, g, b and skipped alpha. The rasteriser test above caught the
// canvas half; this one catches the FILE half, which is where it was seen: a
// rendered PNG that opened as a black rectangle.
test "the fixed-point blend agrees with the float one everywhere" {
    // Differential against the formulation the fixed-point path replaced: every
    // destination byte, every source byte, and alphas across the range. A
    // faster blend that is a byte off somewhere is a rebaseline dressed up as
    // an optimisation, so this is the gate rather than a spot check.
    var mismatches: usize = 0;
    var worst: u8 = 0;
    var a_step: usize = 0;
    while (a_step <= 64) : (a_step += 1) {
        const a = @as(f32, @floatFromInt(a_step)) / 64.0;
        for (0..256) |d| {
            for (0..256) |s| {
                const fast = gamma.blend(@intCast(d), @intCast(s), a);
                const slow = gamma.blendFloat(@intCast(d), @intCast(s), a);
                if (fast != slow) {
                    mismatches += 1;
                    const diff = if (fast > slow) fast - slow else slow - fast;
                    worst = @max(worst, diff);
                }
            }
        }
    }
    // Nothing is printed here even though the numbers are interesting: `zig
    // build test` runs this binary with `--listen=-` and treats stderr as a
    // protocol violation, so a diagnostic on a PASSING run fails the step it was
    // meant to help debug. The count varies with codegen (0 here, 56 in another
    // build), which is exactly what made that failure look intermittent. The two
    // expectations below report both numbers when they break.
    // NOT zero, and the residue is understood: 56 combinations out of 4.26M,
    // every one off by a single code value, all where the exact value lands on
    // an f32 tie. Demanding zero here would be asserting that integer
    // arithmetic reproduces f32 rounding, which is neither true nor wanted --
    // it is the f32 path's error the integer path is being measured against.
    // What actually matters is that no render moved, checked separately: every
    // example PNG is byte-identical to the float build.
    try std.testing.expect(worst <= 1);
    try std.testing.expect(mismatches <= 100);
}

test "coverage blends in light, not in encoded bytes" {
    // Half coverage of white over black. Interpolating the encoded channels
    // gives 127; combining the light gives 188. The two differ by 61 code
    // values at exactly the coverage an antialiased edge sits at, which is why
    // this is an edge defect and not a general one.
    var c = try testCanvas(std.testing.allocator, 4, 4);
    defer c.deinit();
    @memset(c.px, 0);
    const white = elmz.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    c.blendCoverage(1, 1, white, 0.5);
    const i = (1 * 4 + 1) * 4;
    try std.testing.expectApproxEqAbs(@as(f32, 188), @as(f32, @floatFromInt(c.px[i])), 2);

    // Black over white is the same arithmetic by symmetry, and that is the
    // check that this is a transfer fix rather than a brightness nudge.
    @memset(c.px, 255);
    const black = elmz.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    c.blendCoverage(1, 1, black, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 188), @as(f32, @floatFromInt(c.px[i])), 2);

    // Full coverage must still be an exact identity -- no colour drift on the
    // interior of a glyph, where most of the pixels are.
    @memset(c.px, 0);
    const teal = elmz.Color{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 255 };
    c.blendCoverage(1, 1, teal, 1.0);
    try std.testing.expectEqual(@as(u8, 0x89), c.px[i]);
    try std.testing.expectEqual(@as(u8, 0xb4), c.px[i + 1]);
    try std.testing.expectEqual(@as(u8, 0xfa), c.px[i + 2]);
}

test "a painted frame exports opaque pixels through the PNG encoder" {
    var c = try testCanvas(testing.allocator, 12, 6);
    defer c.deinit();
    const base = elmz.Color{ .r = 30, .g = 40, .b = 50, .a = 255 };
    const over = elmz.Color{ .r = 200, .g = 120, .b = 60, .a = 255 };
    c.fillRect(.{ .x = 0, .y = 0, .w = 12, .h = 6 }, .{ .solid = base });
    // A second opaque quad through the blending path, so both routes are covered.
    c.fillRect(.{ .x = 4, .y = 2, .w = 4, .h = 2 }, .{ .solid = over });

    const png = try c.encodePng(testing.allocator);
    defer testing.allocator.free(png);
    const px = try decodeStoredPng(testing.allocator, png);
    defer testing.allocator.free(px);

    try testing.expectEqual(@as(usize, 12 * 6 * 4), px.len);
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 255), px[i + 3]);
    }
    // And the bytes are the ones painted, not a uniform fill.
    const at = struct {
        fn at(b: []const u8, x: usize, y: usize) [4]u8 {
            const o = (y * 12 + x) * 4;
            return .{ b[o], b[o + 1], b[o + 2], b[o + 3] };
        }
    };
    try testing.expectEqual([4]u8{ 200, 120, 60, 255 }, at.at(px, 5, 3));
    try testing.expectEqual([4]u8{ 30, 40, 50, 255 }, at.at(px, 0, 0));
}

test "a string is measured once, then answered from the cache" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 64, 32);
    defer c.deinit();

    const a = Canvas.vtMeasure(&c, "Hamburgefonstiv", 20);
    const b = Canvas.vtMeasure(&c, "Hamburgefonstiv", 20);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.ascent, b.ascent);
    try std.testing.expectEqual(a.line_height, b.line_height);
    try std.testing.expectEqual(@as(usize, 1), c.measure_misses);
    try std.testing.expectEqual(@as(usize, 1), c.measure_hits);

    // A different size is a different question about the same bytes, not a hit.
    const d = Canvas.vtMeasure(&c, "Hamburgefonstiv", 24);
    try std.testing.expectEqual(@as(usize, 2), c.measure_misses);
    try std.testing.expect(d.width > a.width);

    // A different string is a different question at the same size.
    _ = Canvas.vtMeasure(&c, "Ham", 20);
    try std.testing.expectEqual(@as(usize, 3), c.measure_misses);

    // Changing the face must not answer from the old face's widths.
    const sys_font = testing_font.anySystemFont(std.testing.allocator, std.testing.io) orelse return;
    defer std.testing.allocator.free(sys_font);
    c.setFont(sys_font);
    _ = Canvas.vtMeasure(&c, "Hamburgefonstiv", 20);
    try std.testing.expectEqual(@as(usize, 4), c.measure_misses);
}

test "a paragraph is wrapped once, then answered from the cache" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 64, 32);
    defer c.deinit();
    const r = c.renderer();
    const text = "the quick brown fox jumps over the lazy dog";

    var a: [8][]const u8 = undefined;
    var b: [8][]const u8 = undefined;
    const na = r.wrapText(text, 12, 60, &a);
    try std.testing.expect(na > 1);
    try std.testing.expectEqual(@as(usize, 1), c.wrap_misses);

    const nb = r.wrapText(text, 12, 60, &b);
    try std.testing.expectEqual(na, nb);
    try std.testing.expectEqual(@as(usize, 1), c.wrap_hits);
    // A hit rebuilds the slices, so they must land on the same text.
    for (a[0..na], b[0..nb]) |x, y| try std.testing.expectEqualStrings(x, y);

    // A different width is a different question about the same bytes.
    _ = r.wrapText(text, 12, 200, &a);
    try std.testing.expectEqual(@as(usize, 2), c.wrap_misses);

    // And a new face invalidates it, like the measurement cache.
    const sys_font = testing_font.anySystemFont(std.testing.allocator, std.testing.io) orelse return;
    defer std.testing.allocator.free(sys_font);
    c.setFont(sys_font);
    _ = r.wrapText(text, 12, 60, &b);
    try std.testing.expectEqual(@as(usize, 3), c.wrap_misses);
}

/// Ink in a buffer, for tests that care whether anything was painted. A draw
/// that silently produces nothing is the failure mode this counts against.
fn inkPixels(px: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        if (px[i] != 0 or px[i + 1] != 0 or px[i + 2] != 0) n += 1;
    }
    return n;
}

test "a canvas face carries a resolved kern cache" {
    // The kern cache is attached through the same dance as the mask cache, and
    // a null there is not an error anywhere -- `shape` just re-resolves every
    // call. So the wiring needs its own assertion, or a wiring bug costs
    // nothing visible and everything in repeated work.
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 64, 32);
    defer c.deinit();
    const any = withFace(&c) orelse return;
    defer gpa.free(any);
    try std.testing.expect(c.font.kern != null);

    // And it must be for THIS face, not whatever was attached last.
    try std.testing.expect(c.font.kern.?.font.data.ptr == c.font.face.data.ptr);
}

test "the same text drawn twice comes out of the glyph cache" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 160, 40);
    defer c.deinit();
    const any = withFace(&c) orelse return;
    defer gpa.free(any);

    const black: elmz.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const white: elmz.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const fill: elmz.Fill = .{ .solid = white };
    const msg = "Hamburgefonstiv"; // every glyph carries ink, so none is skipped

    c.clear(black);
    c.drawText(2, 4, 16, fill, msg);
    try std.testing.expect(inkPixels(c.px) > 100); // the guard did not swallow it

    const first = try gpa.dupe(u8, c.px);
    defer gpa.free(first);
    const before = c.font.cacheStats() orelse return error.NoCacheAttached;
    try std.testing.expectEqual(msg.len, before.misses);

    // Second pass over a cleared canvas, so the pixels have to come back.
    c.clear(black);
    c.drawText(2, 4, 16, fill, msg);
    const after = c.font.cacheStats().?;

    // No new rasterisation: every glyph in this string was already covered.
    try std.testing.expectEqual(before.misses, after.misses);
    // One hit per glyph asked for.
    try std.testing.expectEqual(msg.len, after.hits - before.hits);
    // And a hit produces the same pixels as the first pass did.
    try std.testing.expectEqualSlices(u8, first, c.px);
}

test "a face with no cache storage measures but paints nothing" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 80, 30);
    defer c.deinit();

    const black: elmz.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const white: elmz.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    const any = testing_font.anySystemFont(gpa, std.testing.io) orelse return;
    defer gpa.free(any);

    // Deliberately NOT attached to any storage -- the state a caller lands in
    // if it builds a face and forgets. It measures, because metrics do not
    // need the cache, and it paints nothing, because the glyph does.
    var f = cedar.Font.init(any);
    try std.testing.expect(f.cacheStats() == null);
    try std.testing.expect(f.measure("Wm", 16).width > 0);

    c.clear(black);
    f.drawText(c.px, c.w, c.h, 2, 2, 16, .{ .solid = white }, "Wm", .{ .x = 0, .y = 0, .w = 80, .h = 30 });
    try std.testing.expectEqual(@as(usize, 0), inkPixels(c.px));
}

test "a canvas with no face still paints text, because the band is text too" {
    var c = try testCanvas(testing.allocator, 140, 24);
    defer c.deinit();

    // A font path the app named and the filesystem could not produce leaves
    // `Font.none` attached. Every diagnostic the runtime raises -- including
    // "cannot read font" -- is drawn with text, so this used to be the one
    // state that reported nothing at all: a blank window, indistinguishable
    // from a broken renderer.
    c.setFont("");
    try testing.expect(!c.font.available());
    try testing.expectEqual(@as(usize, 0), inkPixels(c.px));

    const white: elmz.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    c.drawText(2, 2, 12, .{ .solid = white }, "font is missing");
    try testing.expect(inkPixels(c.px) > 60);
}

test "a caret placed at a byte boundary hit-tests back to that byte" {
    var c = try testCanvas(testing.allocator, 240, 40);
    defer c.deinit();
    const r = c.renderer();
    const text = "Hamburgefonstiv";
    const size: f32 = 16;

    try testing.expectEqual(@as(f32, 0), r.advanceText(text, size, 0));
    // The end of the text IS its measured width. If these disagree, a caret at
    // the end of a field sits off the last glyph.
    try testing.expectApproxEqAbs(
        r.measureText(text, size).width,
        r.advanceText(text, size, text.len),
        0.001,
    );

    // Every boundary round-trips. This is the only statement that catches a
    // caret PLACED by one rule and hit-tested by another, which is what a
    // prefix-measure shortcut against a walked run would do.
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        try testing.expectEqual(i, r.hitText(text, size, r.advanceText(text, size, i)));
    }

    // Outside the text it clamps rather than indexing past either end.
    try testing.expectEqual(text.len, r.hitText(text, size, 10_000));
    try testing.expectEqual(@as(usize, 0), r.hitText(text, size, -10));

    // Advances are monotonic: no boundary sits left of the one before it, which
    // a desynced glyph-codepoint walk would break silently.
    var prev = r.advanceText(text, size, 0);
    i = 1;
    while (i <= text.len) : (i += 1) {
        const x = r.advanceText(text, size, i);
        try testing.expect(x >= prev);
        prev = x;
    }
}

test "the caret round-trips at 1.5x, so the density divide is not forgotten" {
    var c = try testCanvas(testing.allocator, 240, 40);
    defer c.deinit();
    const r = c.renderer();
    const text = "Hamburgefonstiv";
    const size: f32 = 16;
    const at_one = r.advanceText(text, size, text.len);

    c.scale = 1.5;
    // Advances are grid-fitted, so a logical width at 1.5x is not EXACTLY the
    // 1x one -- but it has to be close. Without the divide back it would be
    // half again as wide, which is the failure this is watching for.
    try testing.expectApproxEqAbs(at_one, r.advanceText(text, size, text.len), 1.0);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        try testing.expectEqual(i, r.hitText(text, size, r.advanceText(text, size, i)));
    }
}

test "a faceless canvas still places a caret, on whole cells" {
    var c = try testCanvas(testing.allocator, 140, 24);
    defer c.deinit();
    c.setFont("");
    try testing.expect(!c.font.available());

    const r = c.renderer();
    const text = "caret";
    try testing.expectEqual(@as(f32, 0), r.advanceText(text, 12, 0));
    // Uniform cells, so the same two invariants hold without any glyph data.
    try testing.expectApproxEqAbs(
        r.measureText(text, 12).width,
        r.advanceText(text, 12, text.len),
        0.001,
    );
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        try testing.expectEqual(i, r.hitText(text, 12, r.advanceText(text, 12, i)));
    }
}

test "the built-in face stays out of the way when a real one is attached" {
    var c = try testCanvas(testing.allocator, 200, 24);
    defer c.deinit();
    const any = withFace(&c) orelse return;
    defer testing.allocator.free(any);
    try testing.expect(c.font.available());

    // Not a pixel comparison -- a real face would pass that by accident. This
    // compares the measurement, because the built-in face measures in whole
    // multiples of six and a real one does not: a fallback that quietly took
    // over would be a layout bug wearing a font's clothes.
    const r = c.renderer();
    const real = r.measureText("Hamburgefonstiv", 16);
    const bitmap = elmfont.measure("Hamburgefonstiv", 16);
    try testing.expect(real.width != bitmap.width);

    c.setFont("");
    const gone = c.renderer().measureText("Hamburgefonstiv", 16);
    try testing.expectEqual(bitmap.width, gone.width);
}

test "the built-in face draws exactly the rows its table holds" {
    // Every pixel of every glyph, against the table. Not a smoke test: a
    // transposed bit, an off-by-one pitch or a dropped final column is exactly
    // the class of error that a picture of legible text hides.
    const w = elmfont.order.len * elmfont.advance;
    var c = try testCanvas(testing.allocator, w, elmfont.line_h);
    defer c.deinit();
    c.setFont("");
    c.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    c.drawText(0, 0, 6, .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } }, elmfont.order);

    for (elmfont.order, 0..) |ch, i| {
        const rows = elmfont.glyphFor(ch);
        for (rows, 0..) |row, gy| {
            for (0..elmfont.glyph_w) |gx| {
                const lit = (row >> @intCast(elmfont.glyph_w - 1 - gx)) & 1;
                const ry = gy + elmfont.dyOf(ch);
                const got = c.px[(ry * w + i * elmfont.advance + gx) * 4];
                try testing.expectEqual(@as(u8, if (lit == 1) 255 else 0), got);
            }
        }
    }
}

fn pxAt(c: *const Canvas, x: u32, y: u32) u8 {
    return c.px[(y * c.w + x) * 4];
}

const RED: elmz.Fill = .{ .solid = .{ .r = 255, .g = 0, .b = 0, .a = 255 } };

test "a path fills its interior and nothing past its edges" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 20, 20);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });

    const ops = [_]elmz.PathOp{ .move, .line, .line, .close };
    const pts = [_][2]f32{ .{ 2, 2 }, .{ 18, 2 }, .{ 2, 18 }, .{ 2, 2 } };
    c.pathClip(0, 0, .{ .ops = &ops, .points = &pts }, RED, elmz.Rect.unbounded);

    try std.testing.expect(pxAt(&c, 4, 4) > 200); // inside
    try std.testing.expect(pxAt(&c, 18, 18) == 0); // beyond the hypotenuse
    try std.testing.expect(pxAt(&c, 0, 0) == 0); // outside the bounding box
}

test "even-odd punches the hole that non-zero fills in" {
    const gpa = std.testing.allocator;
    const ops = [_]elmz.PathOp{
        .move, .line, .line, .line, .close,
        .move, .line, .line, .line, .close,
    };
    // Two squares wound the SAME way: under non-zero the inner one adds
    // winding and the middle stays solid; under even-odd it is a hole. That
    // difference is the whole reason the rule is carried on the path.
    const pts = [_][2]f32{
        .{ 2, 2 }, .{ 18, 2 }, .{ 18, 18 }, .{ 2, 18 },
        .{ 6, 6 }, .{ 14, 6 }, .{ 14, 14 }, .{ 6, 14 },
    };

    var solid = try testCanvas(gpa, 20, 20);
    defer solid.deinit();
    solid.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    solid.pathClip(0, 0, .{ .ops = &ops, .points = &pts, .rule = .nonzero }, RED, elmz.Rect.unbounded);
    try std.testing.expect(pxAt(&solid, 10, 10) > 200);

    var holed = try testCanvas(gpa, 20, 20);
    defer holed.deinit();
    holed.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    holed.pathClip(0, 0, .{ .ops = &ops, .points = &pts, .rule = .evenodd }, RED, elmz.Rect.unbounded);
    try std.testing.expect(pxAt(&holed, 10, 10) == 0); // the hole
    try std.testing.expect(pxAt(&holed, 4, 10) > 200); // the ring around it
}

test "a curved path bulges past the chord its controls imply" {
    const gpa = std.testing.allocator;
    var c = try testCanvas(gpa, 20, 20);
    defer c.deinit();
    c.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });

    // A quad from (2,18) through control (10,2) to (18,18) reaches its apex at
    // y = 10, well ABOVE the straight chord at y = 18. A backend that treated
    // the control point as a corner would fill almost nothing here.
    const ops = [_]elmz.PathOp{ .move, .quad, .close };
    const pts = [_][2]f32{ .{ 2, 18 }, .{ 10, 2 }, .{ 18, 18 } };
    c.pathClip(0, 0, .{ .ops = &ops, .points = &pts }, RED, elmz.Rect.unbounded);

    try std.testing.expect(pxAt(&c, 10, 12) > 200); // under the apex: inside
    try std.testing.expect(pxAt(&c, 10, 5) == 0); // above the apex: outside
    try std.testing.expect(pxAt(&c, 10, 17) > 200); // the body below it
}

test "a non-finite rect paints nothing, not the whole clip" {
    // `@min`/`@max` follow fmax/fmin and silently DROP a NaN, so `clipSpan`'s
    // `!(x1 > x0)` guard -- which does catch an inverted rect -- turned a NaN
    // coordinate into the clip's own edge and painted every pixel the clip
    // allowed. Measured before this guard: a 4x4 rect at (NaN,NaN) on a 64x64
    // canvas painted 4096 pixels instead of 0. The damage is inverted from the
    // usual defect: a broken element claims the whole screen instead of
    // vanishing, and no gate notices, because every render that exists has
    // finite coordinates.
    //
    // Infinity is refused for a different reason: `@intFromFloat` traps on it,
    // and the clamp below it happens AFTER the conversion, so it cannot save it.
    var c = try testCanvas(std.testing.allocator, 16, 16);
    defer c.deinit();
    const red = elmz.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const bad = [_]elmz.Rect{
        .{ .x = nan, .y = nan, .w = 4, .h = 4 },
        .{ .x = 4, .y = 4, .w = nan, .h = nan },
        .{ .x = nan, .y = 4, .w = 4, .h = 4 },
        .{ .x = 4, .y = nan, .w = 4, .h = 4 },
        .{ .x = 4, .y = 4, .w = inf, .h = inf },
        .{ .x = -inf, .y = -inf, .w = 4, .h = 4 },
    };
    for (bad) |r| {
        @memset(c.px, 0);
        c.fillRect(r, .{ .solid = red });
        var painted: usize = 0;
        var i: usize = 0;
        while (i < 16 * 16) : (i += 1) {
            if (c.px[i * 4] != 0) painted += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), painted);
    }

    // The guard must refuse ONLY the nonsense: a finite rect beside them still
    // paints, or this test would pass for the wrong reason.
    @memset(c.px, 0);
    c.fillRect(.{ .x = 2, .y = 2, .w = 4, .h = 4 }, .{ .solid = red });
    try std.testing.expectEqual(@as(u8, 255), testRgb(&c, 3, 3)[0]);
}

test "a run of ideographs wraps between characters and loses nothing" {
    var buf: [16][]const u8 = undefined;
    // No spaces anywhere. Under the space-only rule this was one hard break at
    // whatever character happened to overflow; a break opportunity between
    // ideographs is what makes the lines land on character boundaries instead.
    const text = "日本語のテキストです";
    const n = testing_font.get().wrapLines(text, 14, 60, &buf);
    try std.testing.expect(n > 1);
    // Nothing lost, nothing duplicated, nothing reordered: the pieces are
    // consecutive slices of the input.
    var at: usize = 0;
    for (buf[0..n]) |line| {
        try std.testing.expect(line.len > 0);
        try std.testing.expect(std.mem.eql(u8, text[at..][0..line.len], line));
        at += line.len;
    }
    try std.testing.expectEqual(text.len, at);
}

test "punctuation is never stranded at the start of a CJK line" {
    var c = try testCanvas(testing.allocator, 80, 40);
    defer c.deinit();
    const any = withFace(&c) orelse return;
    defer testing.allocator.free(any);
    const r = c.renderer();
    // A face without CJK answers every codepoint with its notdef box, so the
    // break positions would be arbitrary rather than wrong. Nothing to prove.
    if (r.measureText("日", 14).width < 8) return;

    var buf: [16][]const u8 = undefined;
    // 「 opens, 」and 。 close. The natural greedy break lands right on the
    // punctuation, which is what a space-only rule does and what kinsoku
    // forbids: a closing mark belongs to the line before it.
    const text = "「日本語」の文章。";
    const n = r.wrapText(text, 14, 45, &buf);
    try std.testing.expect(n > 1);
    var at: usize = 0;
    for (buf[0..n]) |line| {
        try std.testing.expect(std.mem.eql(u8, text[at..][0..line.len], line));
        at += line.len;
    }
    for (buf[1..n]) |line| {
        try std.testing.expect(!std.mem.startsWith(u8, line, "。"));
        try std.testing.expect(!std.mem.startsWith(u8, line, "」"));
    }
    for (buf[0..n]) |line| {
        try std.testing.expect(!std.mem.endsWith(u8, line, "「"));
    }
}

test "two weights of a variable face differ through the seam" {
    // The seam, end to end: `setFontAt` asks for an instance, and the renderer
    // must answer differently for it. Before this test the path did not exist
    // -- `setFont` took bytes and nothing else, so a variable face could only
    // ever draw its default instance.
    //
    // PIXELS, not advances. An advance comes from `hmtx`/HVAR and can diverge
    // with a dead variation store, so a width comparison cannot prove the
    // OUTLINES moved; this face in particular keeps its advance constant across
    // weight, which makes a width assertion fail for a reason that has nothing
    // to do with the seam. Rasterising the glyph and counting ink is the
    // observation that actually tracks the outline. Cedar's own suite proves
    // the store itself; this proves the seam routes coordinates into it.
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        "/root/NovusGroteskVF-cff2.otf.ttf",
        std.testing.allocator,
        .limited(32 * 1024 * 1024),
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);

    var c = try Canvas.init(std.testing.allocator, 200, 100);
    defer c.deinit();
    const r = c.renderer();

    // The face must really be variable, or the test would pass by drawing the
    // same default twice.
    const probe = @import("cedar.zig").Font.init(bytes);
    if (probe.axisCount() == 0) return error.SkipZigTest;

    const ink: elmz.Fill = .{ .solid = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    const area: elmz.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };

    c.setFontAt(bytes, 0, &.{300});
    r.text(10, 10, 60, ink, "H", area);
    const light_hash = std.hash.Wyhash.hash(0, c.px);
    const light_ink = countInk(c.px);

    @memset(c.px, 0);
    c.setFontAt(bytes, 0, &.{900});
    r.text(10, 10, 60, ink, "H", area);
    const heavy_hash = std.hash.Wyhash.hash(0, c.px);
    const heavy_ink = countInk(c.px);

    // A weight axis moves the OUTLINE: the heavy instance covers measurably
    // more area than the light one.
    try std.testing.expect(light_ink > 0);
    try std.testing.expect(heavy_ink > light_ink);
    try std.testing.expect(light_hash != heavy_hash);

    // And the caches must not answer across instances: redrawing the light
    // instance has to reproduce the light pixels exactly.
    @memset(c.px, 0);
    c.setFontAt(bytes, 0, &.{300});
    r.text(10, 10, 60, ink, "H", area);
    try std.testing.expectEqual(light_hash, std.hash.Wyhash.hash(0, c.px));
}

/// Non-zero pixels in a frame. Used by the variation test to compare how much
/// of the canvas each weight covers.
fn countInk(px: []const u8) usize {
    var n: usize = 0;
    for (px) |p| {
        if (p != 0) n += 1;
    }
    return n;
}

test "a measurement cache does not answer across variation instances" {
    // `setFontAt` clears both caches, so rekeying them is invisible through it.
    // The state that distinguishes `instanceKey` from `fingerprint` is a face
    // swapped WITHOUT a clear -- which is what this asserts directly: the key
    // the caches are filed under must separate two weights of one file.
    //
    // `fingerprint` hashes the BYTES, and two weights are one file, so it
    // collides here and the light measurement would be served to the heavy
    // face. That is precisely the bug the instance key exists to prevent.
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        "/root/NovusGroteskVF-cff2.otf.ttf",
        std.testing.allocator,
        .limited(32 * 1024 * 1024),
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);

    const probe = @import("cedar.zig").Font.init(bytes);
    if (probe.axisCount() == 0) return error.SkipZigTest;

    const light = probe.atCoords(&.{300});
    const heavy = probe.atCoords(&.{900});

    // Same file, so the byte identity is the SAME...
    try std.testing.expectEqual(light.fingerprint(), heavy.fingerprint());
    // ...and the instance identity must NOT be.
    try std.testing.expect(light.instanceKey() != heavy.instanceKey());
}
