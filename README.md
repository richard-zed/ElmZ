# elmz

An Elm-shaped GUI runtime in Zig 0.16, sitting **above** its backend.

A `view` returns a tree of values. Layout measures it, paint emits quads and
text, and a platform turns those into pixels. Nothing survives the frame.

## Layout

| file | role | knows about |
|---|---|---|
| `src/elmz.zig` | tree, layout, primitives, events, `Window` vtable | nothing |
| `src/software.zig` | primitives -> RGBA8888, PNG encoder | `elmz` |
| `src/ttf.zig` | TrueType metrics + rasterisation (stb_truetype) | `elmz` |
| `src/runner.zig` | loop: poll -> hit-test painted frame -> dispatch -> repaint -> present | `elmz`, `software` |
| `src/platform_sdl3.zig` | SDL3 window / input / present; draws nothing | `elmz` |
| `examples/tasks.zig` | a complete app: model, messages, update, view | `elmz`, `software` |
| `examples/tasks_window.zig` | the same app in a window (21 lines) | `runner`, `platform_sdl3` |

Dependencies point downward only. `runner` knows the `Window` vtable, so a
Wayland `wl_shm` backend is a drop-in.

## Build

```sh
zig build test      # 67 tests: library, rasteriser, runner loop
zig build           # counter, gallery, tasks binaries
zig build run-tasks # writes tasks_0..2.png (no display needed)
zig build run-gallery
```

Window builds need SDL3 **and only those** touch it:

```sh
zig build run-tasks-sdl3
zig build run-counter-sdl3
zig build run-gallery-sdl3
```

If `pkg-config --modversion sdl3` fails, install it (`libsdl3-dev`,
`SDL3-devel`, `sdl3`) or skip the window targets — everything else builds
offline, including the font and stb_truetype, which are vendored.

## Writing an app

```zig
pub const app = .{
    .title = "tasks",
    .size  = .{ .w = 360, .h = 268 },
    .bg    = elmz.Color.rgbHex(0x141821),
    .Model = Model, .Msg = Msg,
    .update = update, .view = view,
};
```

`view` is infallible: builders return `*Element(Msg)`, never an error union.
An allocation failure is recorded on the `Ui` and the frame degrades instead of
aborting, which is the only sane answer when there is nothing left to do about
it.

`runner.runApp(app, gpa, window)` derives the canvas, the background and the
runtime from that one declaration, so size and colour exist in exactly one
place.

## Commands (async)

`update` returns `Action(Msg)`, which can carry a `cmd`. The runtime runs it on
a worker thread; the result arrives as an ordinary message, dispatched by the
loop. While a command is in flight the loop polls with a 5ms timeout instead of
blocking, so results surface without waiting for input.

```zig
.start => |job| return .{ .cmd = .{ .ctx = job, .run = compute } },
```

`ctx` must outlive the job; the runtime joins its workers on `deinit`.

## Text

UTF-8 is decoded to codepoints before glyph lookup, so multibyte text measures
and draws as characters rather than bytes. `Renderer.measureText` returns

```zig
TextMetrics{ width, height, ascent, descent, line_height }
```

with the vertical values taken from the font, so `line_height` is the font's own
spacing rather than a multiple of the point size.

`ui.paragraph(bytes, size)` wraps: greedy at spaces, honours `\n`, and an
overlong single word gets its own line rather than looping. It takes no width —
`measure(self, r, avail_w)` is handed the width the parent is about to give it,
and the same number is used to lay it out, which is what keeps `measure` and
`paint` breaking at the same place. Set `e.width` to hold a paragraph narrower
than its container. Wrapped text is capped at `elmz.max_lines` (32) — beyond
that lines are dropped, not allocated.

`Renderer.wrapText` is the seam: it writes slices that point into the caller's
bytes, so wrapping allocates nothing and the core never touches font internals.

## Theme

Two files live beside the binary -- `zig-out/bin/theme.zon` and
`zig-out/bin/theme.defaults.zon` -- and a relative `theme_path` is resolved
against the executable's own directory, not the cwd. Launch it from anywhere
and it looks the same.

- `theme.defaults.zon` -- every legal key, at its library default. It is the
  listing, not a backup: copy it, delete what you do not want to change, and
  the rest inherits.
- `theme.zon` -- the live file. An app that declares `theme_path` loads it
  before the first frame and re-reads it when it changes on disk, so a window
  recolours on save. A file that will not parse keeps the last good palette and
  puts the loader's own `file line:col: reason` in the error band.

Both are seeded on the first build and then never overwritten, so a rebuild
will not revert an edit. `zig build theme` is the deliberate overwrite: it
restores both from their masters (`src/theme.defaults.zon`, the listing
embedded in the library, and `examples/showcase.theme.zon`, the warm sample),
which makes it the reset button after a bad edit.

`zig build run-X` runs the *installed* copy, not the cache artifact, so a run
sees the same files a hand-launched binary does. (`addRunArtifact` spawns
`.zig-cache/o/<hash>/`, where no theme file exists -- every run used to fall
back to compiled defaults while `zig-out/bin/showcase` picked the theme up.)

Precedence, from the bottom up: the palette compiled into the library, then
`theme.defaults.zon` beside the binary (the app author's house palette), then
`theme.zon` (the end user's override, which inherits anything it omits). An app
is themed entirely in `.zon` -- nothing here asks anyone to edit Zig. A missing
defaults file inherits the library's palette; an unparseable one keeps it and
puts the file:line diagnostic in the error band.

Both files are watched, and *either* one changing re-resolves the whole chain.
That is not tidiness: the override is resolved against the base, so reloading a
`theme.defaults.zon` edit on its own would leave `theme.zon` resolved against a
palette that no longer exists. One resolver serves startup and reload, so the
two cannot disagree.

Watching the files costs one bounded poll per loop iteration -- 250ms by
default, `theme_poll_ms` -- because the stat happens at the top of the loop.
With an unbounded wait an edit is only noticed when the pointer enters the
window, which reads as the theme file doing nothing until you touch it. A file
that disappears is deliberately ignored: editors save by unlinking and
renaming, so a transient absence is ordinary, and dropping the palette
mid-save would flash the fallback colours at the worst possible moment.

## Known gaps

- No window has ever been run on a screen from this tree. `platform_sdl3.zig`
  typechecks against real SDL3 3.5.0 headers, nothing more.
- `src/font.ttf` is a full 744KB DejaVu. Subsetting works (`fontTools` is
  available; ASCII+Latin-1 comes out at 45KB) but the subsetter always drops
  the legacy `kern` table and only rewrites GPOS, and stb_truetype reads only
  `kern` — so a subset silently turns kerning off. Either generate a `kern`
  table for the subset or teach the shaper GPOS before taking the 700KB win.
- No CJK coverage. UTF-8 decodes any codepoint, but the embedded font has no
  glyphs past Latin-1, so other scripts fall back to .notdef.
- Clip rects are square only. Setting `clips = true` on an element confines its
  descendants to its rect, and primitives wholly outside are dropped at emit
  time rather than handed to the rasterizer — so hit testing needs no clip
  logic of its own. Rounded corners are not cut: a rect clip on a rounded
  container still leaks into the corners, because a rounded clip cannot be
  expressed as a clamped rect and would have to travel with the primitive.
- No diffing: every change rebuilds the whole tree and repaints every pixel.
