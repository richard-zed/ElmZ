const std = @import("std");

pub fn build(b: *std.Build) void {
    // Run the INSTALLED copy, not the cache artifact.
    //
    // `addRunArtifact` spawns the file under `.zig-cache/o/<hash>/`, and a
    // theme file resolved against the executable's directory therefore finds
    // nothing there -- every run silently fell back to compiled defaults while
    // a hand-launched `zig-out/bin/showcase` picked the theme up. Running the
    // installed copy makes `zig build run-X` and running the binary by hand
    // exercise the same layout, which is the layout that ships.
    //
    // cwd stays pinned to the project root: run steps inherit the caller's cwd
    // by default (`Child.Cwd.inherit` in std/Build/Step/Run.zig), and the PNGs
    // they write belong next to the tree, not wherever you typed `zig build`.
    const runExample = struct {
        fn f(bld: *std.Build, artifact: *std.Build.Step.Compile) *std.Build.Step.Run {
            const install = bld.addInstallArtifact(artifact, .{});
            const r = bld.addSystemCommand(&.{bld.getInstallPath(.bin, artifact.name)});
            r.step.dependOn(&install.step);
            r.setCwd(bld.path("."));
            return r;
        }
    }.f;

    // The theme files live beside the binary, and a relative `theme_path` is
    // resolved against the executable's directory -- so a copy of the app reads
    // the copy's own theme, and the cwd cannot change how it looks.
    //
    // Seeded once, at configure time, and never overwritten: after the first
    // build the file belongs to whoever is editing it and a rebuild must not
    // silently revert an edit. `zig build theme` is the deliberate overwrite,
    // which is why that step is the documented reset button.
    {
        const io = b.graph.io;
        const cwd = std.Io.Dir.cwd();
        // The listing `.zon` themes are written against: seeded as a file so it
        // can be read, copied and edited without a rebuild. There is no second
        // seed -- no live `theme.zon` ships, so the reset button restores one
        // master rather than two.
        //
        // Exclusive create, so "seed it" and "never revert an edit" are the same
        // operation: if the file is already there, whoever put it there wins and
        // this is a no-op. A missing master is skipped silently, because a dev
        // tree mid-edit should not stop configuring -- which is also why the
        // step is the documented reset.
        if (cwd.readFileAlloc(io, "src/theme.defaults.zon", b.allocator, .limited(64 * 1024))) |data| {
            defer b.allocator.free(data);
            const dst = b.getInstallPath(.bin, "theme.defaults.zon");
            if (std.fs.path.dirname(dst)) |d| cwd.createDirPath(io, d) catch {};
            if (cwd.createFile(io, dst, .{ .exclusive = true })) |file| {
                defer file.close(io);
                file.writeStreamingAll(io, data) catch {};
            } else |_| {}
        } else |_| {}
    }

    const theme_step = b.step("theme", "restore theme.defaults.zon beside the binary");
    theme_step.dependOn(&b.addInstallFileWithDir(
        b.path("src/theme.defaults.zon"),
        .bin,
        "theme.defaults.zon",
    ).step);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const elmz_mod = b.addModule("elmz", .{
        .root_source_file = b.path("src/elmz.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Cedar, the font backend, comes from its own package. Pinned by commit
    // and hash in build.zig.zon, so a clone builds the same code this tree was
    // verified against -- and no path on one machine is baked into the build.
    const cedar_dep = b.dependency("glyfz", .{ .target = target, .optimize = optimize });
    const cedar_mod = cedar_dep.module("glyfz");

    const software_mod = b.addModule("software", .{
        .root_source_file = b.path("src/software.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "elmz", .module = elmz_mod }},
        .link_libc = true,
    });
    // No C in the font path any more: Cedar is Zig, so nothing is compiled
    // from a translation unit and nothing is included from src/.
    software_mod.addImport("glyfz", cedar_mod);

    // the loop: needs elmz + software, knows no platform
    const runner_mod = b.addModule("runner", .{
        .root_source_file = b.path("src/runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "elmz", .module = elmz_mod },
            .{ .name = "software", .module = software_mod },
        },
    });

    // headless example: no window at all
    const exe = b.addExecutable(.{
        .name = "counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/counter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const exe_install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&exe_install.step);
    b.step("counter", "build the headless counter").dependOn(&exe_install.step);

    const fonts = b.addExecutable(.{
        .name = "fonts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/fonts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const fonts_install = b.addInstallArtifact(fonts, .{});
    b.getInstallStep().dependOn(&fonts_install.step);
    b.step("fonts", "build the headless font demo").dependOn(&fonts_install.step);

    const gallery = b.addExecutable(.{
        .name = "gallery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/gallery.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const gallery_install = b.addInstallArtifact(gallery, .{});
    b.getInstallStep().dependOn(&gallery_install.step);
    b.step("gallery", "build the headless gallery").dependOn(&gallery_install.step);

    b.step("run-gallery", "render the gallery to gallery_*.png (headless)").dependOn(
        &runExample(b, gallery).step,
    );

    // ---------------------------------------------------------------------
    // tasks: the small app that shows what a clean one looks like
    // ---------------------------------------------------------------------
    const tasks = b.addExecutable(.{
        .name = "tasks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tasks.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const tasks_install = b.addInstallArtifact(tasks, .{});
    b.getInstallStep().dependOn(&tasks_install.step);
    b.step("tasks", "build the headless tasks app").dependOn(&tasks_install.step);
    b.step("run-tasks", "render the tasks app to tasks_*.png (headless)").dependOn(&runExample(b, tasks).step);

    const radius_exe = b.addExecutable(.{
        .name = "radius",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/radius.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const radius_exe_install = b.addInstallArtifact(radius_exe, .{});
    b.getInstallStep().dependOn(&radius_exe_install.step);
    b.step("radius", "build the headless radii render").dependOn(&radius_exe_install.step);
    b.step("run-radius", "render corner radii to radius.png (headless)").dependOn(
        &runExample(b, radius_exe).step,
    );

    const paint_exe = b.addExecutable(.{
        .name = "paint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/paint.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const paint_exe_install = b.addInstallArtifact(paint_exe, .{});
    b.getInstallStep().dependOn(&paint_exe_install.step);
    b.step("paint", "build the headless fills render").dependOn(&paint_exe_install.step);

    const effects_exe = b.addExecutable(.{
        .name = "effects",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/effects.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
            },
        }),
    });
    const effects_exe_install = b.addInstallArtifact(effects_exe, .{});
    b.getInstallStep().dependOn(&effects_exe_install.step);
    b.step("effects", "build the shadow + frost render").dependOn(&effects_exe_install.step);

    const path_exe = b.addExecutable(.{
        .name = "path",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/path.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
            },
        }),
    });
    const path_exe_install = b.addInstallArtifact(path_exe, .{});
    b.getInstallStep().dependOn(&path_exe_install.step);
    b.step("path", "build the outline fill render").dependOn(&path_exe_install.step);
    b.step("run-path", "render outline fills to path.png (headless)").dependOn(
        &runExample(b, path_exe).step,
    );
    const overlay_exe = b.addExecutable(.{
        .name = "overlay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/overlay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const overlay_exe_install = b.addInstallArtifact(overlay_exe, .{});
    b.getInstallStep().dependOn(&overlay_exe_install.step);
    b.step("overlay", "build the debug overlay render (headless)").dependOn(&overlay_exe_install.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
            },
        }),
    });
    const bench_install = b.addInstallArtifact(bench_exe, .{});
    b.getInstallStep().dependOn(&bench_install.step);
    b.step("bench", "build the profiling harness").dependOn(&bench_install.step);
    b.step("run-bench", "measure build and paint by prim count (headless)").dependOn(
        &runExample(b, bench_exe).step,
    );

    b.step("run-paint", "render gradient fills to paint.png (headless)").dependOn(
        &runExample(b, paint_exe).step,
    );
    b.step("run-overlay", "render the debug overlay to overlay.png (headless)").dependOn(
        &runExample(b, overlay_exe).step,
    );

    const showcase_exe = b.addExecutable(.{
        .name = "showcase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const glow_exe = b.addExecutable(.{
        .name = "glow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/glow.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    glow_exe.root_module.addImport("elmz", elmz_mod);
    glow_exe.root_module.addImport("runner", runner_mod);
    glow_exe.root_module.addImport("software", software_mod);
    const glow_exe_install = b.addInstallArtifact(glow_exe, .{});
    b.getInstallStep().dependOn(&glow_exe_install.step);
    b.step("glow", "build the glow/shadow demo").dependOn(&glow_exe_install.step);
    b.step("run-glow", "render glow.png and glow-hover.png (headless)").dependOn(
        &runExample(b, glow_exe).step,
    );

    const showcase_exe_install = b.addInstallArtifact(showcase_exe, .{});
    b.getInstallStep().dependOn(&showcase_exe_install.step);
    b.step("showcase", "build the headless showcase").dependOn(&showcase_exe_install.step);
    b.step("run-showcase", "render a full screen to showcase*.png (headless)").dependOn(
        &runExample(b, showcase_exe).step,
    );

    // ---------------------------------------------------------------------
    // clicks: the press-owns-the-click rule, as something you can click
    // ---------------------------------------------------------------------
    const clicks = b.addExecutable(.{
        .name = "clicks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/clicks.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const clicks_install = b.addInstallArtifact(clicks, .{});
    b.getInstallStep().dependOn(&clicks_install.step);
    b.step("clicks", "build the headless clicks app").dependOn(&clicks_install.step);
    b.step("run-clicks", "run the click-ownership app headlessly (asserts the cases, writes clicks.png)").dependOn(
        &runExample(b, clicks).step,
    );

    b.step("run-fonts", "render the font demo headlessly (writes fonts*.png)").dependOn(
        &runExample(b, fonts).step,
    );

    const run = runExample(b, exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run-counter", "run the headless counter (writes frame_*.png)").dependOn(&run.step);

    // ---------------------------------------------------------------------
    // tests: elmz core + the runner loop (fake window, no display needed)
    // ---------------------------------------------------------------------
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/elmz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
            },
        }),
    });

    const software_tests = b.addTest(.{ .root_module = software_mod });

    const test_step = b.step("test", "run core + software + runner tests");
    test_step.dependOn(&b.addRunArtifact(software_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(runner_tests).step);

    // ---------------------------------------------------------------------
    // the -sdl3 variants. Only built when asked for, so a machine without
    // SDL3 still gets a working `zig build` for everything else. Each one is the
    // SAME app as its headless example, in a window: counter -> counter-sdl3.
    // ---------------------------------------------------------------------
    const sdl_mod = b.createModule(.{
        .root_source_file = b.path("src/platform_sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "elmz", .module = elmz_mod }},
    });
    sdl_mod.linkSystemLibrary("SDL3", .{});

    const tasks_win = b.addExecutable(.{
        .name = "tasks-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tasks_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // tasks_window pulls in the app file (tasks.zig), which imports
                // elmz and software itself: they have to be in scope HERE, on
                // the module that owns that file, or the app file cannot see
                // them.
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("run-tasks-sdl3", "run the tasks app in an SDL3 window").dependOn(
        &runExample(b, tasks_win).step,
    );
    b.step("tasks-sdl3", "build the tasks app in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(tasks_win, .{}).step,
    );

    const win_exe = b.addExecutable(.{
        .name = "counter-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/counter_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });

    b.step("counter-sdl3", "build the counter in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(win_exe, .{}).step,
    );
    b.step("run-counter-sdl3", "run the counter in an SDL3 window").dependOn(
        &runExample(b, win_exe).step,
    );

    const gal_win = b.addExecutable(.{
        .name = "gallery-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/gallery_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("run-gallery-sdl3", "run the gallery in an SDL3 window").dependOn(
        &runExample(b, gal_win).step,
    );
    b.step("gallery-sdl3", "build the gallery in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(gal_win, .{}).step,
    );

    const clicks_win = b.addExecutable(.{
        .name = "clicks-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/clicks_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("clicks-sdl3", "build the clicks app in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(clicks_win, .{}).step,
    );
    b.step("run-clicks-sdl3", "run the click-ownership app in an SDL3 window").dependOn(
        &runExample(b, clicks_win).step,
    );

    const glow_win = b.addExecutable(.{
        .name = "glow-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/glow_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("glow-sdl3", "build the glow demo in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(glow_win, .{}).step,
    );
    b.step("run-glow-sdl3", "run the glow demo in an SDL3 window").dependOn(
        &runExample(b, glow_win).step,
    );

    const paint_win = b.addExecutable(.{
        .name = "paint-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/paint_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("paint-sdl3", "build the fills app in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(paint_win, .{}).step,
    );
    b.step("run-paint-sdl3", "run the fills app in an SDL3 window").dependOn(
        &runExample(b, paint_win).step,
    );

    const show_win = b.addExecutable(.{
        .name = "showcase-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("showcase-sdl3", "build the showcase in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(show_win, .{}).step,
    );
    b.step("run-showcase-sdl3", "run the showcase in an SDL3 window").dependOn(
        &runExample(b, show_win).step,
    );

    // radius had a `view` and no `app` declaration, which is exactly why it had
    // no window: the composition layer needs something to bind to.
    const radius_win = b.addExecutable(.{
        .name = "radius-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/radius_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    const radius_win_install = b.addInstallArtifact(radius_win, .{});
    b.step("radius-sdl3", "build the radii render in an SDL3 window (needs libsdl3-dev)").dependOn(&radius_win_install.step);
    b.step("run-radius-sdl3", "run the radii render in an SDL3 window").dependOn(
        &runExample(b, radius_win).step,
    );

    // ---------------------------------------------------------------------
    // `zig build examples` -- EVERY example, headless and windowed.
    //
    // This is the compile gate the window binaries never had. `zig build test`
    // builds only the declared test roots and `zig build` builds only what is
    // in the install set, so a window example could rot for weeks while every
    // suite stayed green -- the same false-green class as test-does-not-build-
    // examples. Here they are all in one step, and a broken one fails it.
    //
    // It needs libsdl3-dev, or `--search-prefix` pointing at one. The headless
    // set is what `zig build` installs, so a machine without SDL3 still has a
    // working default build; this step is the deliberate, explicit ask.
    // ---------------------------------------------------------------------
    // The pre-widgets screen: a viewport with its automatic thumb, tabs, and a
    // popup dismissed by a press that claimed nothing. Built by `zig build` (so
    // it cannot rot unused) and by `zig build examples` with its window.
    const panes = b.addExecutable(.{
        .name = "panes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/panes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
            },
        }),
    });
    const panes_install = b.addInstallArtifact(panes, .{});
    b.getInstallStep().dependOn(&panes_install.step);
    b.step("panes", "build the headless panes example").dependOn(&panes_install.step);
    b.step("run-panes", "run the headless panes example").dependOn(&runExample(b, panes).step);

    const panes_win = b.addExecutable(.{
        .name = "panes-sdl3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/panes_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "elmz", .module = elmz_mod },
                .{ .name = "software", .module = software_mod },
                .{ .name = "runner", .module = runner_mod },
                .{ .name = "platform_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.step("panes-sdl3", "build panes in an SDL3 window (needs libsdl3-dev)").dependOn(
        &b.addInstallArtifact(panes_win, .{}).step,
    );
    b.step("run-panes-sdl3", "run panes in an SDL3 window").dependOn(
        &runExample(b, panes_win).step,
    );

    const examples_step = b.step("examples", "build every example: headless + all SDL3 windows (windows need libsdl3-dev)");

    // headless
    examples_step.dependOn(&exe_install.step);
    examples_step.dependOn(&gallery_install.step);
    examples_step.dependOn(&tasks_install.step);
    examples_step.dependOn(&radius_exe_install.step);
    examples_step.dependOn(&paint_exe_install.step);
    examples_step.dependOn(&effects_exe_install.step);
    examples_step.dependOn(&path_exe_install.step);
    examples_step.dependOn(&overlay_exe_install.step);
    examples_step.dependOn(&bench_install.step);
    examples_step.dependOn(&showcase_exe_install.step);
    examples_step.dependOn(&glow_exe_install.step);
    examples_step.dependOn(&clicks_install.step);
    examples_step.dependOn(&panes_install.step);

    // sdl3 windows
    examples_step.dependOn(&b.addInstallArtifact(win_exe, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(tasks_win, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(gal_win, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(clicks_win, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(glow_win, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(paint_win, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(show_win, .{}).step);
    examples_step.dependOn(&radius_win_install.step);
    examples_step.dependOn(&b.addInstallArtifact(panes_win, .{}).step);
}
