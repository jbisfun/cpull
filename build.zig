const std = @import("std");

pub fn build(b: *std.Build) void {
    const xit_dep = b.dependency("xit", .{});
    const xml_mod = b.dependency("xml", .{}).module("xml");
    const ansi_art = ansiArtModule(b);
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    // the web UI: "wiki" (src/frontend, the jbisfun wiki theme) or "classic"
    // (haxy's own terminal-grid web UI with the wasm client)
    const frontend = b.option(enum { wiki, classic }, "frontend", "Web UI to build: wiki (default) or classic") orelse .wiki;
    const vin_mod = b.dependency("vin", .{}).module("zig-vin");

    // wasm
    const wasm_exe = blk: {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });

        const exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_wasm.zig"),
                .target = wasm_target,
                .optimize = .small,
            }),
        });
        exe.root_module.addImport("xit", xit_dep.module("xit"));

        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.import_memory = false;
        exe.export_memory = true;
        // parsing the page json at startup holds many routes on the stack, so
        // main_wasm.zig checks the route size against it
        const stack_pages = 64;
        const stack_size = std.wasm.page_size * stack_pages;
        exe.stack_size = stack_size;
        const options = b.addOptions();
        options.addOption(u64, "stack_size", stack_size);
        exe.root_module.addOptions("build_options", options);

        // start small past the stack and let the allocator grow on demand up
        // to wasm32's architectural ceiling (65536 pages = 4 GiB)
        const initial_pages = stack_pages + 16;
        const max_pages = 65536;
        exe.initial_memory = std.wasm.page_size * initial_pages;
        exe.max_memory = std.wasm.page_size * max_pages;

        const install_exe = b.addInstallArtifact(exe, .{});

        const wasm_step = b.step("wasm", "Generate the wasm");
        wasm_step.dependOn(&install_exe.step);

        break :blk exe;
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // the CI's job queue (src/ci); links libc. its C library is always built
    // optimized, so debug builds of haxy don't run a debug SQLite
    const sqlite_mod = b.dependency("sqlite", .{ .target = target, .optimize = .ReleaseFast }).module("sqlite");

    // main
    {
        const exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                // default to ReleaseSafe unless an explicit -Doptimize is passed
                .optimize = if (b.user_input_options.contains("optimize")) optimize else .safe,
            }),
            .use_llvm = true,
        });
        exe.root_module.addImport("xit", xit_dep.module("xit"));
        exe.root_module.addImport("xml", xml_mod);
        exe.root_module.addImport("ansi_art", ansi_art);
        exe.root_module.addAnonymousImport("haxy.wasm", .{
            .root_source_file = wasm_exe.getEmittedBin(),
        });
        addFrontend(b, exe.root_module, vin_mod, frontend == .wiki);
        exe.root_module.addImport("sqlite", sqlite_mod);

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
    }

    // test
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        unit_tests.root_module.addImport("xit", xit_dep.module("xit"));
        unit_tests.root_module.addImport("xml", xml_mod);
        unit_tests.root_module.addImport("ansi_art", ansi_art);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);

        // the themed-page layer stands alone (std + vin)
        const theme_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/theme/theme.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        theme_tests.root_module.addImport("vin", vin_mod);
        test_step.dependOn(&b.addRunArtifact(theme_tests).step);

        // the CI (src/ci), with the haxy frontend it renders beside
        const ci_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test_ci.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        ci_tests.root_module.addImport("xit", xit_dep.module("xit"));
        ci_tests.root_module.addImport("xml", xml_mod);
        ci_tests.root_module.addImport("ansi_art", ansi_art);
        ci_tests.root_module.addImport("vin", vin_mod);
        ci_tests.root_module.addImport("sqlite", sqlite_mod);
        const run_ci_tests = b.addRunArtifact(ci_tests);
        run_ci_tests.has_side_effects = true;
        test_step.dependOn(&run_ci_tests.step);
    }

    // module for using haxy as a library
    // (the commands below consume haxy this way)
    const haxy = b.addModule("haxy", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    haxy.addImport("xit", xit_dep.module("xit"));
    haxy.addImport("xml", xml_mod);
    haxy.addImport("ansi_art", ansi_art);
    haxy.addImport("sqlite", sqlite_mod);
    haxy.addImport("vin", vin_mod);
    haxy.addAnonymousImport("haxy.wasm", .{
        .root_source_file = wasm_exe.getEmittedBin(),
    });

    // try
    {
        const exe = b.addExecutable(.{
            .name = "try",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_demo.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("haxy", haxy);
        const try_install = b.addInstallArtifact(exe, .{});

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&try_install.step);
        run_cmd.addPassthruArgs();

        const run_step = b.step("try", "Try the app");
        run_step.dependOn(&run_cmd.step);
    }

    // testnet
    {
        const server_exe = b.addExecutable(.{
            .name = "haxy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = .debug,
            }),
            .use_llvm = true,
        });
        server_exe.root_module.addImport("xit", xit_dep.module("xit"));
        server_exe.root_module.addImport("xml", xml_mod);
        server_exe.root_module.addImport("ansi_art", ansi_art);
        server_exe.root_module.addAnonymousImport("haxy.wasm", .{
            .root_source_file = wasm_exe.getEmittedBin(),
        });
        // the network tests read haxy's own web UI
        addFrontend(b, server_exe.root_module, vin_mod, false);
        server_exe.root_module.addImport("sqlite", sqlite_mod);
        const install_server_exe = b.addInstallArtifact(server_exe, .{});

        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testnet.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        unit_tests.root_module.addImport("haxy", haxy);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        run_unit_tests.step.dependOn(&install_server_exe.step);
        const test_step = b.step("testnet", "Run network unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}

// the imports src/main.zig's haxy_frontend needs: whether the wiki theme is
// built in, and the template engine it renders with
fn addFrontend(b: *std.Build, module: *std.Build.Module, vin_mod: *std.Build.Module, themed: bool) void {
    const options = b.addOptions();
    options.addOption(bool, "themed", themed);
    module.addOptions("frontend_options", options);
    module.addImport("vin", vin_mod);
}

// reads every ANSI-art text file while configuring the build. sorting keeps
// the generated module stable when directory iteration order changes.
fn ansiArtModule(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("src/embed/ansi"));
    b.dependOnFileContents(b.path("src/embed/not-found.txt"));
    var dir = b.root.openDir(io, "src/embed/ansi", .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open src/embed/ansi: {t}", .{err});
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch |err| std.debug.panic("unable to read src/embed/ansi: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        names.append(b.allocator, b.graph.dupeString(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    if (names.items.len == 0) @panic("src/embed/ansi must contain at least one .txt file");

    const contents = b.allocator.alloc([]const u8, names.items.len) catch @panic("OOM");
    for (names.items, contents) |name, *content| {
        b.dependOnFileContents(b.path(b.fmt("src/embed/ansi/{s}", .{name})));
        content.* = dir.readFileAlloc(io, name, b.allocator, .limited(16 * 1024 * 1024)) catch |err| {
            std.debug.panic("unable to read src/embed/ansi/{s}: {t}", .{ name, err });
        };
    }

    var embed_dir = b.root.openDir(io, "src/embed", .{}) catch unreachable;
    defer embed_dir.close(io);
    const not_found = embed_dir.readFileAlloc(io, "not-found.txt", b.allocator, .limited(16 * 1024 * 1024)) catch unreachable;

    const options = b.addOptions();
    options.addOption([]const []const u8, "art", contents);
    options.addOption([]const u8, "not_found", not_found);
    return options.createModule();
}
