// what the themed frontend (src/frontend/cpull) shows of the other tools:
// idlci's CI status for repos, commits, patches and stacks, the merge gate's
// verdict, an issue's references, and issue mentions turned into links.
// Every function answers null (or the text unchanged) when the page isn't
// served by a workspace server, when idlci isn't running, or on any error,
// so pages never fail over it. One `Render` per page holds the idlci
// connection and what it already asked for.
const std = @import("std");
const theme = @import("theme");
const tools = @import("tools.zig");
const forge = @import("../forge.zig");
const idlci = @import("idlci.zig");
const status = @import("status.zig");
const runs = @import("runs.zig");
const gate = @import("gate.zig");
const links = @import("links.zig");
const ws_mod = @import("../workspace.zig");

pub const Summary = status.Summary;
pub const CommitIndex = status.CommitIndex;
pub const References = links.References;

// a page's view of idlci: connected on first use, closed by `deinit`
pub const Render = struct {
    arena: *std.heap.ArenaAllocator,
    state: enum { unknown, down, up } = .unknown,
    client: idlci.Client = undefined,
    // GET /api/status/repos, once per page
    repos: ?std.json.Value = null,
    repos_tried: bool = false,

    pub fn init(arena: *std.heap.ArenaAllocator) Render {
        return .{ .arena = arena };
    }

    pub fn deinit(r: *Render) void {
        if (r.state == .up) r.client.deinit();
        r.state = .down;
    }

    // idlci, when this is a workspace server's page and it's running
    pub fn ci(r: *Render) ?*idlci.Client {
        switch (r.state) {
            .up => return &r.client,
            .down => return null,
            .unknown => {
                r.state = .down;
                const ws = tools.workspace orelse return null;
                r.client = tools.connectIdlci(ws.io, r.arena.allocator(), ws.root) orelse return null;
                r.state = .up;
                return &r.client;
            },
        }
    }
};

// idlci is running for this workspace server
pub fn enabled(r: *Render) bool {
    return r.ci() != null;
}

fn repoOf(identity: []const u8) ?ws_mod.Repo {
    const ws = tools.workspace orelse return null;
    return ws.byIdentity(identity);
}

// a pullfile repo's CI ball (its idl projects' latest workspace jobs)
pub fn repoStatus(r: *Render, repo_name: []const u8) ?Summary {
    const c = r.ci() orelse return null;
    if (repo_name.len == 0) return null;
    if (!r.repos_tried) {
        r.repos_tried = true;
        r.repos = c.get("/api/status/repos") catch null;
    }
    if (r.repos) |all| if (all == .object) {
        const v = all.object.get(repo_name) orelse return null;
        return status.parseSummary(c, v);
    };
    const path = std.fmt.allocPrint(c.a, "/api/status/repo/{s}", .{idlci.pathEscape(c.a, repo_name) catch return null}) catch return null;
    return status.parseSummary(c, c.get(path) catch return null);
}

pub fn repoStatusOf(r: *Render, identity: []const u8) ?Summary {
    const repo = repoOf(identity) orelse return null;
    return repoStatus(r, repo.name);
}

// the CI jobs of a repo's sidebar group: one row per project + command
pub fn repoGroup(r: *Render, identity: []const u8) ?theme.Group {
    const s = repoStatusOf(r, identity) orelse return null;
    const aa = r.arena.allocator();
    const rows = aa.alloc(theme.Row, s.jobs.len) catch return null;
    for (s.jobs, rows) |j, *row| row.* = .{ .label = j.label, .href = j.href, .ball = j.ball, .detail = j.when, .title = std.fmt.allocPrint(aa, "#{d} {s}", .{ j.id, j.status }) catch "" };
    return .{ .title = "CI", .rows = rows, .more_href = s.href, .more_label = "details" };
}

pub fn commitIndex(r: *Render, identity: []const u8) ?CommitIndex {
    const c = r.ci() orelse return null;
    const repo = repoOf(identity) orelse return null;
    return links.commitIndex(c, forge.displayName(repo));
}

// a patch's CI: its latest run, whether it's current, and the run form
pub const PatchCi = struct {
    summary: ?Summary,
    run_action: []const u8 = web_run_patch,
    repo: []const u8,
    id: []const u8,
    back: []const u8,
    note: []const u8 = "",
};

// cpull's form routes that ask idlci to run (tools/web.zig)
pub const web_run_patch = "/_ci/run/patch";
pub const web_run_stack = "/_ci/run/stack";

pub fn patchCi(r: *Render, identity: []const u8, patch_id: []const u8, source_branch: ?[]const u8, back: []const u8) ?PatchCi {
    const ws = tools.workspace orelse return null;
    const c = r.ci() orelse return null;
    const repo = repoOf(identity) orelse return null;
    if (repo.name.len == 0) return null;
    const aa = r.arena.allocator();
    const branch = source_branch orelse return .{ .summary = null, .repo = repo.name, .id = patch_id, .back = back, .note = "A patch from a fork has no branch here for CI to check out." };
    const tip = forge.branchTip(ws.io, aa, repo.path, branch);
    const tips = if (tip) |t| std.fmt.allocPrint(aa, "{s} {s}", .{ repo.name, t }) catch null else null;
    const subject = runs.patchSubject(aa, repo.name, patch_id) catch return null;
    var summary = gate.forSubject(c, subject, tips) catch null;
    // no run of its own: what ran on its tip (a stack's run, the watcher's)
    if (summary == null) if (tip) |t| {
        if (links.commitIndex(c, repo.name)) |index| if (index.get(t)) |found| {
            summary = found;
            summary.?.label = std.fmt.allocPrint(aa, "{s} on its tip", .{found.label}) catch found.label;
        };
    };
    return .{ .summary = summary, .repo = repo.name, .id = patch_id, .back = back };
}

pub fn patchBall(r: *Render, repo_name: []const u8, patch_id: []const u8) ?Summary {
    const c = r.ci() orelse return null;
    return gate.forSubject(c, runs.patchSubject(c.a, repo_name, patch_id) catch return null, null) catch null;
}

// a stack's CI and the merge gate
pub const StackCi = struct {
    summary: ?Summary,
    run_action: []const u8 = web_run_stack,
    id: []const u8,
    back: []const u8,
    // the pullfile requires green CI to merge
    required: bool = false,
    // merging is allowed by the gate
    gate_ok: bool = true,
    gate_reason: []const u8 = "",
};

pub fn stackCi(r: *Render, stack_id: []const u8, back: []const u8) ?StackCi {
    const ws = tools.workspace orelse return null;
    const required = tools.config(ws.io, ws.gpa, ws.root).require_ci;
    const c = r.ci() orelse {
        // no CI to show, but a required gate still blocks the merge
        if (!required) return null;
        return .{ .summary = null, .id = stack_id, .back = back, .required = true, .gate_ok = false, .gate_reason = "CI not reachable (idlci isn't running)" };
    };
    const aa = r.arena.allocator();
    const members = runs.stackMembers(ws, r.arena, stack_id) catch &.{};
    const tips = runs.tips(aa, members) catch null;
    var out: StackCi = .{ .summary = gate.forSubject(c, runs.stackSubject(aa, stack_id) catch return null, tips) catch null, .id = stack_id, .back = back };
    if (gate.verdictWith(c, ws, r.arena, stack_id, required)) |v| {
        out.required = v.required;
        out.gate_ok = v.ok;
        out.gate_reason = v.reason;
    } else |_| {}
    return out;
}

pub fn stackBall(r: *Render, stack_id: []const u8) ?Summary {
    const c = r.ci() orelse return null;
    return gate.forSubject(c, runs.stackSubject(c.a, stack_id) catch return null, null) catch null;
}

pub fn issueRefs(r: *Render, identity: []const u8, issue_id: []const u8) ?References {
    const ws = tools.workspace orelse return null;
    const repo = repoOf(identity) orelse return null;
    const refs = links.references(ws, r.arena, r.ci(), repo, issue_id) catch return null;
    return if (refs.empty()) null else refs;
}

// a commit message as html, its issue mentions linked
pub fn linkHtml(r: *Render, identity: []const u8, text: []const u8) ?theme.vin.Str {
    const ws = tools.workspace orelse return null;
    const repo = repoOf(identity) orelse return null;
    var resolver: links.Resolver = .{ .ws = ws, .arena = r.arena, .repo = repo };
    return theme.markup(links.link(&resolver, text, .html) catch return null);
}

// like linkHtml, but null unless some mention became a link
pub fn linkHtmlIfAny(r: *Render, identity: []const u8, text: []const u8) ?theme.vin.Str {
    if (std.mem.indexOfScalar(u8, text, '#') == null) return null;
    const html = linkHtml(r, identity, text) orelse return null;
    return if (std.mem.indexOf(u8, html.bytes, "<a href=") != null) html else null;
}

// markdown with its issue mentions as links
pub fn linkMarkdown(r: *Render, identity: []const u8, text: []const u8) []const u8 {
    const ws = tools.workspace orelse return text;
    const repo = repoOf(identity) orelse return text;
    var resolver: links.Resolver = .{ .ws = ws, .arena = r.arena, .repo = repo };
    return links.link(&resolver, text, .markdown) catch text;
}

// a stack's description (in the events repo) with mentions of any repo's issues linked
pub fn linkStackMarkdown(r: *Render, text: []const u8) []const u8 {
    const ws = tools.workspace orelse return text;
    const events = ws.events orelse return text;
    var resolver: links.Resolver = .{ .ws = ws, .arena = r.arena, .repo = events, .everywhere = true };
    return links.link(&resolver, text, .markdown) catch text;
}
