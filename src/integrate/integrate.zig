// cpull's forge x CI x issues integration, over a pull workspace:
//
// * CI status everywhere (status.zig): a status ball for each repo's idl
//   projects on the workspace pages, repo pages and per commit in the history,
//   and for patches and stacks.
// * CI for patches and stacks (patchci.zig, ci/work.zig): build + test a
//   patch's source branch, or every member of a stack together, in a
//   pull-style work tree under .pull/cpull/ci/work/; and the merge gate
//   (gate.zig, pullfile `cpull.require_ci`) that refuses to merge a stack whose
//   CI isn't green, unless forced.
// * Failed CI -> issue (ciissue.zig): a failing default-branch job files (or
//   comments on) one `ci` issue per target in its repo, closed when it passes.
// * Commit <-> issue links (links.zig): `#<id prefix>` in commit messages and
//   patch descriptions links the issue, `fixes #id` / `closes #id` closes it
//   once the commit lands on the default branch, and issue pages list what
//   references them.
// * Shutdown (shutdown.zig): SIGTERM/SIGINT cancel the running jobs' process
//   groups before the server exits.
//
// main.zig calls `install` once the workspace server's CI is up; the themed
// frontend reads through view.zig.
const std = @import("std");
const ws_mod = @import("../workspace.zig");
const pullfile = @import("../pullfile.zig");
const ci = @import("../ci/ci.zig");

pub const forge = @import("forge.zig");
pub const status = @import("status.zig");
pub const patchci = @import("patchci.zig");
pub const gate = @import("gate.zig");
pub const ciissue = @import("ciissue.zig");
pub const links = @import("links.zig");
pub const shutdown = @import("shutdown.zig");
pub const view = @import("view.zig");

const Workspace = ws_mod.Workspace;
const log = std.log.scoped(.integrate);

// the workspace server's workspace and CI, once installed
pub var workspace: ?*Workspace = null;
pub var app: ?*ci.App = null;

pub const Options = struct {
    // poll the default branches for `fixes #id` every this many seconds
    links_interval: u64 = 30,
};

// wire the integration into a workspace server: the merge gate, the CI
// issue hook, the commit-link scanner and the shutdown handler
pub fn install(w: *Workspace, ci_app: ?*ci.App, opts: Options) void {
    workspace = w;
    app = ci_app;
    ws_mod.merge_gate = gate.check;
    if (ci_app) |a| {
        a.runner.on_finish = .{ .ctx = a, .f = ciissue.onFinish };
        // only the server running the jobs files issues and closes them, once
        if (a.workers) links.start(w, a, opts.links_interval);
        shutdown.install(a);
    }
}

// the gate alone, for `cpull stack merge` (no server; the gate opens the CI db itself)
pub fn installCli() void {
    ws_mod.merge_gate = gate.check;
}

pub const Config = struct {
    require_ci: bool = false,
    ci_issues: bool = true,
    close_issues: bool = true,
};

// the pullfile's `cpull` switches, read fresh each time (pull may rewrite it)
pub fn config(io: std.Io, gpa: std.mem.Allocator, root: []const u8) Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const pf = pullfile.load(io, arena.allocator(), root) catch return .{};
    return .{ .require_ci = pf.require_ci, .ci_issues = pf.ci_issues, .close_issues = pf.close_issues };
}

test {
    _ = links;
    _ = status;
    _ = ciissue;
}
