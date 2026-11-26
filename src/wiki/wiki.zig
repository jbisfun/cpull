//! `cpull wiki`: one static site from every repo in a pull workspace (the
//! Zig port of the Rust `wiki` tool, jbisfun/wiki/src).
//!
//! Each repo's README is its entry page, its `docs/` folder becomes pages, and
//! rustdoc / LDoc / JSDoc produce its code reference. Git object ids decide
//! what has to be regenerated (state.zig). The wiki repo (`<root>/wiki`) stays
//! the site's data: wiki.toml, templates/, pages/, assets/, locales/ and the
//! translations/ cache. Output and state live under
//! `<root>/.pull/cpull/wiki/` (`dist/`, `build/`); the workspace server
//! serves `dist/` live at /wiki/ (serve.zig).
const std = @import("std");
const sys_mod = @import("sys.zig");
const config = @import("config.zig");
const collect = @import("collect.zig");
const apidoc = @import("apidoc.zig");
const bundle = @import("bundle.zig");
const render = @import("render.zig");
const state_mod = @import("state.zig");
pub const serve = @import("serve.zig");

pub const Sys = sys_mod.Sys;

// as the test root: quiet superhtml's per-character debug log
pub const std_options: std.Options = .{ .log_scope_levels = &.{.{ .scope = .@"html/tokenizer", .level = .info }} };
pub const Paths = render.Paths;

pub const Options = struct {
    action: enum { build, publish, clean },
    force: bool = false,
    workspace_path: ?[]const u8 = null,
};

/// The wiki repo, the workspace root and the output dirs.
pub fn findPaths(sys: Sys, cwd: []const u8, workspace: ?[]const u8) !Paths {
    const a = sys.arena;
    var root: ?[]const u8 = if (workspace) |w| try std.Io.Dir.path.resolve(a, &.{ cwd, w }) else sys.getenv("PULL_ROOT");
    var wiki: ?[]const u8 = null;
    if (root) |r| {
        if (sys.isFile(sys.join(&.{ r, "wiki", "wiki.toml" }))) wiki = sys.join(&.{ r, "wiki" });
    }
    if (wiki == null) {
        // a wiki.toml above the current dir
        var dir: ?[]const u8 = cwd;
        while (dir) |d| : (dir = std.Io.Dir.path.dirname(d)) {
            if (sys.isFile(sys.join(&.{ d, "wiki.toml" }))) {
                wiki = d;
                break;
            }
        }
    }
    if (root == null) {
        // the pull workspace around the current dir, else the wiki repo's parent
        var dir: ?[]const u8 = cwd;
        while (dir) |d| : (dir = std.Io.Dir.path.dirname(d)) {
            if (sys.isFile(sys.join(&.{ d, "pullfile.plist" }))) {
                root = d;
                break;
            }
        }
        if (root == null) if (wiki) |w| {
            root = std.Io.Dir.path.dirname(w);
        };
        if (wiki == null) if (root) |r| if (sys.isFile(sys.join(&.{ r, "wiki", "wiki.toml" }))) {
            wiki = sys.join(&.{ r, "wiki" });
        };
    }
    const w = wiki orelse return error.NoWikiToml;
    const r = root orelse return error.NoWorkspace;
    const out = sys.getenv("CPULL_WIKI_DIR") orelse sys.join(&.{ r, ".pull", "cpull", "wiki" });
    return .{ .wiki = w, .root = r, .build = sys.join(&.{ out, "build" }), .dist = sys.join(&.{ out, "dist" }) };
}

pub const Result = render.Result;

/// Build the site into `paths.dist`, regenerating only what changed.
pub fn build(sys: Sys, paths: Paths, force: bool) !Result {
    const state_path = sys.join(&.{ paths.build, "state.json" });
    var state: state_mod.State = if (force) .{} else state_mod.State.load(sys, state_path);
    const toml_path = sys.join(&.{ paths.wiki, "wiki.toml" });
    const cfg = config.parse(sys.arena, try sys.readFile(toml_path)) catch |err| {
        std.debug.print("wiki: parsing {s}: {t}\n", .{ toml_path, err });
        return err;
    };
    const repos = try collect.collect(sys, paths.root, &cfg);
    const apis = try apidoc.generate(sys, .{ .wiki = paths.wiki, .build = paths.build }, repos, &state);
    try bundle.bundle(sys, paths.wiki, paths.dist, &state);
    const result = try render.render(sys, paths, &cfg, repos, &apis, &state, bundle.selfId(sys));
    try state.save(sys, state_path);
    return result;
}

/// Mirror dist/ into the GitHub Pages repo and stage it, so the pull
/// precommit hook lands the site in the same `pull commit`.
pub fn publish(sys: Sys, paths: Paths) !void {
    const target = sys.getenv("WIKI_PUBLISH_DIR") orelse sys.join(&.{ paths.root, "jbisfun.github.io" });
    const from = try std.fmt.allocPrint(sys.arena, "{s}/", .{paths.dist});
    const to = try std.fmt.allocPrint(sys.arena, "{s}/", .{target});
    const rsync = sys.run(&.{ "rsync", "-a", "--delete", "--exclude", ".git", "--exclude", "CNAME", "--exclude", "README.md", from, to }, null);
    if (!rsync.ok) {
        std.debug.print("wiki: rsync into {s} failed: {s}\n", .{ target, rsync.stderr });
        return error.PublishFailed;
    }
    try sys.writeFile(sys.join(&.{ target, ".nojekyll" }), "");
    const add = sys.run(&.{ "git", "add", "-A", "." }, target);
    if (!add.ok) {
        std.debug.print("wiki: git add in {s} failed: {s}\n", .{ target, add.stderr });
        return error.PublishFailed;
    }
    const staged = sys.run(&.{ "git", "diff", "--cached", "--name-only", "-z" }, target);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, staged.stdout, 0);
    while (it.next()) |name| {
        if (name.len > 0) count += 1;
    }
    std.debug.print("wiki: published to {s} ({d} files staged)\n", .{ target, count });
}

/// `cpull wiki build|publish|clean [--force] [--workspace DIR]`.
pub fn runCommand(io: std.Io, gpa: std.mem.Allocator, cwd: []const u8, options: Options, err: *std.Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sys: Sys = .{ .io = io, .arena = arena_state.allocator() };
    const paths = findPaths(sys, cwd, options.workspace_path) catch |e| {
        try err.print("cpull wiki: no wiki.toml in <workspace>/wiki or above {s} ({t})\n", .{ cwd, e });
        return error.HandledError;
    };
    switch (options.action) {
        .clean => {
            try sys.removeTree(paths.build);
            try sys.removeTree(paths.dist);
        },
        .build => _ = build(sys, paths, options.force) catch |e| {
            try err.print("cpull wiki: build failed: {t}\n", .{e});
            return error.HandledError;
        },
        .publish => {
            _ = build(sys, paths, options.force) catch |e| {
                try err.print("cpull wiki: build failed: {t}\n", .{e});
                return error.HandledError;
            };
            publish(sys, paths) catch return error.HandledError;
        },
    }
}

test {
    _ = @import("markdown.zig");
    _ = @import("html.zig");
    _ = @import("fluent.zig");
    _ = @import("state.zig");
    _ = @import("config.zig");
    _ = @import("collect.zig");
    _ = @import("translate.zig");
    _ = @import("render.zig");
    _ = @import("apidoc.zig");
    _ = @import("bundle.zig");
    _ = @import("serve.zig");
}
