//! Client assets into <dist>/_assets: `bun build` bundles and minifies
//! assets/main.js with its npm imports (bootstrap, clipboard from the wiki's
//! node_modules) and assets/style.css with its `@import`s (Bootstrap), to
//! which the code highlighting CSS is appended. assets/icons/ is copied as is.
//! (The Rust wiki embedded rolldown and lightningcss; there is no Zig
//! bundler, so this runs an existing one; `$WIKI_BUN` overrides the binary.)
const std = @import("std");
const state_mod = @import("state.zig");
const highlight = @import("highlight.zig");
const Sys = @import("sys.zig").Sys;

pub fn bundle(sys: Sys, wiki: []const u8, dist: []const u8, state: *state_mod.State) !void {
    const out = sys.join(&.{ dist, "_assets" });
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.appendSlice(sys.arena, try state_mod.dirIds(sys, sys.join(&.{ wiki, "assets" })));
    try inputs.append(sys.arena, state_mod.fileId(sys, sys.join(&.{ wiki, "pnpm-lock.yaml" })));
    try inputs.append(sys.arena, selfId(sys));
    const key = state_mod.key(sys.arena, inputs.items);
    if (std.mem.eql(u8, state.assets, key) and sys.isFile(sys.join(&.{ out, "main.js" })) and sys.isFile(sys.join(&.{ out, "style.css" }))) return;

    try sys.removeTree(out);
    try sys.mkdirs(out);
    const bun = sys.getenv("WIKI_BUN") orelse "bun";
    const js = sys.run(&.{ bun, "build", "./assets/main.js", "--minify", "--format=esm", "--outfile", sys.join(&.{ out, "main.js" }) }, wiki);
    if (!js.ok) {
        std.debug.print("wiki: bun build assets/main.js failed (is bun installed, and `pnpm install` run in {s}?)\n{s}{s}\n", .{ wiki, js.stdout, js.stderr });
        return error.BundleFailed;
    }
    const css_path = sys.join(&.{ out, "style.css" });
    const css = sys.run(&.{ bun, "build", "./assets/style.css", "--minify", "--outfile", css_path }, wiki);
    if (!css.ok) {
        std.debug.print("wiki: bun build assets/style.css failed\n{s}{s}\n", .{ css.stdout, css.stderr });
        return error.BundleFailed;
    }
    const sheet = try sys.readFile(css_path);
    try sys.writeFile(css_path, try std.mem.concat(sys.arena, u8, &.{ sheet, try highlight.css(sys.arena) }));
    const icons = sys.join(&.{ wiki, "assets", "icons" });
    if (sys.isDir(icons)) try sys.copyDir(icons, sys.join(&.{ out, "icons" }));
    state.assets = key;
}

/// Blob id of the running binary: a new build re-renders everything.
pub fn selfId(sys: Sys) []const u8 {
    const path = std.process.executablePathAlloc(sys.io, sys.arena) catch return "";
    return state_mod.fileId(sys, path);
}
