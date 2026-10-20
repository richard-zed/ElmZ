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
        for ([_][2][]const u8{
            .{ "src/theme.defaults.zon", "theme.defaults.zon" },
            .{ "examples/showcase.theme.zon", "theme.zon" },
        }) |pair| {
            const dst = b.getInstallPath(.bin, pair[1]);
            if (std.fs.path.dirname(dst)) |d| cwd.createDirPath(io, d) catch {};
            const data = cwd.readFileAlloc(io, pair[0], b.allocator, .limited(64 * 1024)) catch continue;
            defer b.allocator.free(data);
            // Exclusive create, so "seed it" and "never revert an edit" are the
            // same operation: if the file is already there, whoever put it there
            // wins and this is a no-op.
            const file = cwd.createFile(io, dst, .{ .exclusive = true }) catch continue;
            defer file.close(io);
            file.writeStreamingAll(io, data) catch continue;
        }
    }

    const theme_step = b.step("theme", "restore theme.zon and theme.defaults.zon beside the binary");
    theme_step.dependOn(&b.addInstallFileWithDir(
        b.path("src/theme.defaults.zon"),
        .bin,
        "theme.defaults.zon",
    ).step);
    theme_step.dependOn(&b.addInstallFileWithDir(
        b.path("examples/showcase.theme.zon"),
        .bin,
        "theme.zon",
    ).step);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const elmz_mod = b.addModule("elmz", .{
        .root_source_file = b.path("src/elmz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const software_mod = b.addModule("software", .{
        .root_source_file = b.path("src/software.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "elmz", .module = elmz_mod }},
        .link_libc = true,
    });
    // stb_truetype: the implementation must be a C translation unit (the
    // STB_TRUETYPE_IMPLEMENTATION define can't live inside @cImport), so it is
    // added here and included from src/ttf.zig.
    software_mod.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{} });
    software_mod.addIncludePath(b.path("src"));

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
    b.step("run-paint", "render gradient fills to paint.png (headless)").dependOn(
        &runExample(b, paint_exe).step,
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
}
