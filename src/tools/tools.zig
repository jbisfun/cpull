// cpull and the workspace's other tools (theme docs/workspace-tools.md):
// cpull is the forge; idlci (CI), the wiki and radar (reports) are programs
// of their own, which cpull reaches over their HTTP/JSON APIs only.
//
// * CI status everywhere (view.zig, from idlci's /api/status routes): a ball
//   for each repo's idl projects on the workspace and repo pages, per commit
//   in the history, and for patches and stacks; "Run CI" on a patch or stack
//   page posts the members to idlci's /api/runs (runs.zig, web.zig).
// * The merge gate (gate.zig, pullfile `cpull.require_ci`): cpull decides,
//   from idlci's projects and subject statuses; with idlci down and the gate
//   on, nothing merges unless forced.
// * Failed CI -> issue (ciissue.zig): cpull polls idlci's /api/feed and
//   files, comments on, reopens or closes one `ci` issue per failing target.
// * Commit <-> issue links (links.zig): `#id` links, `fixes #id` closing
//   issues when commits land, and what references an issue.
//
// Their state lives in `.pull/cpull/integrate.json` (state.zig). main.zig
// calls `install` for the workspace server; the frontend reads view.zig.
const std = @import("std");
const ws_mod = @import("../workspace.zig");
const pullfile = @import("../pullfile.zig");

pub const idlci = @import("idlci.zig");
pub const status = @import("status.zig");
pub const state = @import("state.zig");
pub const runs = @import("runs.zig");
pub const gate = @import("gate.zig");
pub const ciissue = @import("ciissue.zig");
pub const links = @import("links.zig");
pub const view = @import("view.zig");
pub const web = @import("web.zig");

const Workspace = ws_mod.Workspace;
const log = std.log.scoped(.integrate);

// the workspace server's workspace, once installed
pub var workspace: ?*Workspace = null;
// the process environment ($IDLCI_ADDR)
pub var environ: ?*const std.process.Environ.Map = null;
var stopping: std.atomic.Value(bool) = .init(false);

pub const Options = struct {
    // poll the default branches for `fixes #id` every this many seconds
    links_interval: u64 = 30,
    // poll idlci's feed (a long poll of up to this many seconds)
    feed_wait: u64 = 20,
};

// the workspace server's workspace: pages show the other tools, merges go
// through the gate
pub fn install(w: *Workspace, env: ?*const std.process.Environ.Map) void {
    workspace = w;
    environ = env;
    ws_mod.merge_gate = gate.check;
}

// once this process serves the workspace (it holds .pull/cpull/serve.lock):
// the commit-link scanner and the CI feed poller, so issues are filed and
// closed by one process only
pub fn startServing(opts: Options) void {
    const w = workspace orelse return;
    links.start(w, opts.links_interval);
    ciissue.start(w, opts.feed_wait);
}

// the gate alone, for `cpull stack merge` (no server)
pub fn installCli(env: ?*const std.process.Environ.Map) void {
    environ = env;
    ws_mod.merge_gate = gate.check;
}

pub fn stop() void {
    stopping.store(true, .release);
}

pub fn stopped() bool {
    return stopping.load(.acquire);
}

// idlci for the workspace at `root`, or null when it isn't running
pub fn connectIdlci(io: std.Io, a: std.mem.Allocator, root: []const u8) ?idlci.Client {
    return idlci.Client.connect(io, a, root, environ);
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
    _ = idlci;
    _ = status;
    _ = state;
    _ = links;
    _ = ciissue;
    _ = gate;
    _ = runs;
}
