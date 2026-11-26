const std = @import("std");

pub fn build(b: *std.Build) void {
    const xit_dep = b.dependency("xit", .{});
    const xml_mod = b.dependency("xml", .{}).module("xml");
    const ansi_art = ansiArtModule(b);
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    // the web UI: "wiki" (src/frontend, the jbisfun wiki theme) or "classic"
    // (cpull's own terminal-grid web UI with the wasm client)
    const frontend = b.option(enum { wiki, classic }, "frontend", "Web UI to build: wiki (default) or classic") orelse .wiki;
    const vin_mod = b.dependency("vin", .{}).module("zig-vin");

    // wasm
    const wasm_exe = blk: {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });

        const exe = b.addExecutable(.{
            .name = "cpull",
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
            .name = "cpull",
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
        exe.root_module.addAnonymousImport("cpull.wasm", .{
            .root_source_file = wasm_exe.getEmittedBin(),
        });
        addFrontend(b, exe.root_module, vin_mod, frontend == .wiki);
        exe.root_module.addImport("sqlite", sqlite_mod);
        addWiki(b, exe.root_module, vin_mod, target, exe.root_module.optimize.?);

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
        addWiki(b, unit_tests.root_module, vin_mod, target, optimize);

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

        // the CI (src/ci), with the cpull frontend it renders beside
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

        // the wiki generator (src/wiki) stands alone too
        const wiki_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wiki/wiki.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
            .use_llvm = true,
        });
        addWiki(b, wiki_tests.root_module, vin_mod, target, optimize);
        test_step.dependOn(&b.addRunArtifact(wiki_tests).step);
    }

    // module for using cpull as a library
    // (the commands below consume cpull this way)
    const cpull = b.addModule("cpull", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    cpull.addImport("xit", xit_dep.module("xit"));
    cpull.addImport("xml", xml_mod);
    cpull.addImport("ansi_art", ansi_art);
    cpull.addImport("sqlite", sqlite_mod);
    cpull.addImport("vin", vin_mod);
    cpull.addAnonymousImport("cpull.wasm", .{
        .root_source_file = wasm_exe.getEmittedBin(),
    });
    addWiki(b, cpull, vin_mod, target, optimize);

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
        exe.root_module.addImport("cpull", cpull);
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
            .name = "cpull",
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
        server_exe.root_module.addAnonymousImport("cpull.wasm", .{
            .root_source_file = wasm_exe.getEmittedBin(),
        });
        // the network tests read cpull's own web UI
        addFrontend(b, server_exe.root_module, vin_mod, false);
        server_exe.root_module.addImport("sqlite", sqlite_mod);
        addWiki(b, server_exe.root_module, vin_mod, target, .debug);
        const install_server_exe = b.addInstallArtifact(server_exe, .{});

        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testnet.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        unit_tests.root_module.addImport("cpull", cpull);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        run_unit_tests.step.dependOn(&install_server_exe.step);
        const test_step = b.step("testnet", "Run network unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}

// the imports src/main.zig's cpull_frontend needs: whether the wiki theme is
// built in, and the template engine it renders with
fn addFrontend(b: *std.Build, module: *std.Build.Module, vin_mod: *std.Build.Module, themed: bool) void {
    const options = b.addOptions();
    options.addOption(bool, "themed", themed);
    module.addOptions("frontend_options", options);
    module.addImport("vin", vin_mod);
}

// the imports of the wiki generator (src/wiki, `cpull wiki`): cmark-gfm (C,
// built here; adapted from abhinav/libcmark-gfm.zig), uucode, superhtml's
// html tokenizer, zig-toml and zig-vin
fn addWiki(b: *std.Build, module: *std.Build.Module, vin_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const cmark = b.dependency("cmark_gfm", .{});
    const config = b.addConfigHeader(.{ .style = .{ .cmake = cmark.path("src/config.h.in") } }, .{
        .HAVE_STDBOOL_H = true,
        .HAVE___BUILTIN_EXPECT = true,
        .HAVE___ATTRIBUTE__ = true,
    });
    const version = b.addConfigHeader(.{ .style = .{ .cmake = cmark.path("src/cmark-gfm_version.h.in") } }, .{
        .PROJECT_VERSION_MAJOR = "0",
        .PROJECT_VERSION_MINOR = "29",
        .PROJECT_VERSION_PATCH = "0",
        .PROJECT_VERSION_GFM = "13",
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cmark-gfm",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.root_module.addConfigHeader(config);
    lib.root_module.addConfigHeader(version);
    lib.root_module.addIncludePath(b.path("src/wiki/c"));
    lib.root_module.addIncludePath(cmark.path("src"));
    lib.root_module.addIncludePath(cmark.path("extensions"));
    lib.root_module.addCMacro("CMARK_GFM_STATIC_DEFINE", "1");
    lib.root_module.addCMacro("CMARK_GFM_EXTENSIONS_STATIC_DEFINE", "1");
    lib.root_module.addCSourceFiles(.{
        .root = cmark.path("src"),
        .files = &.{ "xml.c", "cmark.c", "man.c", "buffer.c", "blocks.c", "cmark_ctype.c", "inlines.c", "latex.c", "houdini_href_e.c", "syntax_extension.c", "houdini_html_e.c", "plaintext.c", "utf8.c", "references.c", "render.c", "iterator.c", "arena.c", "linked_list.c", "commonmark.c", "map.c", "html.c", "plugin.c", "scanners.c", "footnotes.c", "houdini_html_u.c", "registry.c", "node.c" },
        .flags = &.{"-std=c99"},
    });
    lib.root_module.addCSourceFiles(.{
        .root = cmark.path("extensions"),
        .files = &.{ "core-extensions.c", "table.c", "strikethrough.c", "autolink.c", "tagfilter.c", "ext_scanners.c", "tasklist.c" },
        .flags = &.{"-std=c99"},
    });
    module.linkLibrary(lib);
    // tree-sitter and the grammars highlight.zig embeds (parser + scanner,
    // and queries/highlights.scm as an anonymous import for @embedFile)
    const ts = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize, .amalgamated = true });
    module.linkLibrary(ts.artifact("tree-sitter"));
    // (name, package, source dir, has an external scanner, highlights query);
    // a library each, for its own headers
    inline for (.{
        .{ "bash", "bash", "src", true, "queries/highlights.scm" },
        .{ "json", "json", "src", false, "queries/highlights.scm" },
        .{ "rust", "rust", "src", true, "queries/highlights.scm" },
        .{ "python", "python", "src", true, "queries/highlights.scm" },
        .{ "javascript", "javascript", "src", true, "queries/highlights.scm" },
        .{ "yaml", "yaml", "src", true, "queries/highlights.scm" },
        .{ "toml", "toml", "src", true, "queries/highlights.scm" },
        .{ "zig", "zig", "src", false, "queries/highlights.scm" },
        .{ "lua", "lua", "src", true, "queries/highlights.scm" },
        .{ "diff", "diff", "src", false, "queries/highlights.scm" },
        .{ "c", "c", "src", false, "queries/highlights.scm" },
        .{ "objc", "objc", "src", false, "queries/highlights.scm" },
        .{ "swift", "swift", "src", true, "queries/highlights.scm" },
        .{ "html", "html", "src", true, "queries/highlights.scm" },
        .{ "css", "css", "src", true, "queries/highlights.scm" },
        .{ "typescript", "typescript", "typescript/src", true, "queries/highlights.scm" },
        .{ "tsx", "typescript", "tsx/src", true, "queries/highlights.scm" },
        .{ "xml", "xml", "xml/src", true, "queries/xml/highlights.scm" },
        .{ "markdown", "markdown", "tree-sitter-markdown/src", true, "tree-sitter-markdown/queries/highlights.scm" },
        .{ "ruby", "ruby", "src", true, "queries/highlights.scm" },
        .{ "make", "make", "src", false, "queries/highlights.scm" },
        .{ "ini", "ini", "src", false, "queries/highlights.scm" },
    }) |grammar| {
        const name = grammar[0];
        const dep = b.dependency("ts_" ++ grammar[1], .{});
        const glib = b.addLibrary(.{
            .linkage = .static,
            .name = "tree-sitter-" ++ name,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .sanitize_c = .off }),
        });
        glib.root_module.addIncludePath(dep.path(grammar[2]));
        glib.root_module.addCSourceFiles(.{
            .root = dep.path(grammar[2]),
            .files = if (grammar[3]) &.{ "parser.c", "scanner.c" } else &.{"parser.c"},
            .flags = &.{"-std=c11"},
        });
        module.linkLibrary(glib);
        module.addAnonymousImport("ts_" ++ name ++ "_highlights", .{ .root_source_file = dep.path(grammar[4]) });
    }
    module.addImport("regex", b.dependency("regex", .{ .target = target, .optimize = optimize }).module("regex"));
    module.addImport("vin", vin_mod);
    module.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"));
    module.addImport("superhtml", b.dependency("superhtml", .{ .target = target, .optimize = optimize }).module("superhtml"));
    module.addImport("uucode", b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{ "general_category", "simple_lowercase_mapping", "script" }),
    }).module("uucode"));
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
