// what the themed frontend (src/frontend/cpull) shows of the integration:
// CI status for repos, commits, patches and stacks, the merge gate's verdict,
// an issue's references, and issue mentions turned into links. Every function
// answers null (or the text unchanged) when the page isn't served by a
// workspace server with CI, or on any error, so pages never fail over it.
const std = @import("std");
const theme = @import("../frontend/theme/theme.zig");
const db = @import("../ci/db.zig");
const integrate = @import("integrate.zig");
const forge = @import("forge.zig");
const status = @import("status.zig");
const patchci = @import("patchci.zig");
const gate = @import("gate.zig");
const links = @import("links.zig");
const ws_mod = @import("../workspace.zig");

pub const Summary = status.Summary;
pub const CommitIndex = status.CommitIndex;
pub const References = links.References;

// served by a workspace server with CI
pub fn enabled() bool {
    return store() != null;
}

fn store() ?*db.Store {
    const app = integrate.app orelse return null;
    return app.store;
}

fn repoOf(identity: []const u8) ?ws_mod.Repo {
    const ws = integrate.workspace orelse return null;
    return ws.byIdentity(identity);
}

// a pullfile repo's CI ball (its idl projects' latest workspace jobs)
pub fn repoStatus(arena: *std.heap.ArenaAllocator, repo_name: []const u8) ?Summary {
    const s = store() orelse return null;
    if (repo_name.len == 0) return null;
    return status.forRepo(arena.allocator(), s, repo_name) catch null;
}

pub fn repoStatusOf(arena: *std.heap.ArenaAllocator, identity: []const u8) ?Summary {
    const repo = repoOf(identity) orelse return null;
    return repoStatus(arena, repo.name);
}

// the CI jobs of a repo's sidebar group: one row per project + command
pub fn repoGroup(arena: *std.heap.ArenaAllocator, identity: []const u8) ?theme.Group {
    const s = repoStatusOf(arena, identity) orelse return null;
    const aa = arena.allocator();
    const rows = aa.alloc(theme.Row, s.jobs.len) catch return null;
    for (s.jobs, rows) |j, *row| row.* = .{ .label = j.label, .href = j.href, .ball = j.ball, .detail = j.when, .title = std.fmt.allocPrint(aa, "#{d} {s}", .{ j.id, j.status }) catch "" };
    return .{ .title = "CI", .rows = rows, .more_href = s.href, .more_label = "details" };
}

pub fn commitIndex(arena: *std.heap.ArenaAllocator, identity: []const u8) ?CommitIndex {
    const s = store() orelse return null;
    const repo = repoOf(identity) orelse return null;
    return status.commitIndex(arena.allocator(), s, forge.displayName(repo)) catch null;
}

// a patch's CI: its latest run, whether it's current, and the run form
pub const PatchCi = struct {
    summary: ?Summary,
    run_action: []const u8 = "/ci/run/patch",
    repo: []const u8,
    id: []const u8,
    back: []const u8,
    note: []const u8 = "",
};

pub fn patchCi(arena: *std.heap.ArenaAllocator, identity: []const u8, patch_id: []const u8, source_branch: ?[]const u8, back: []const u8) ?PatchCi {
    const ws = integrate.workspace orelse return null;
    const s = store() orelse return null;
    const repo = repoOf(identity) orelse return null;
    if (repo.name.len == 0) return null;
    const aa = arena.allocator();
    const branch = source_branch orelse return .{ .summary = null, .repo = repo.name, .id = patch_id, .back = back, .note = "A patch from a fork has no branch here for CI to check out." };
    const tip = forge.branchTip(ws.io, aa, repo.path, branch);
    const tips = if (tip) |t| std.fmt.allocPrint(aa, "{s} {s}", .{ repo.name, t }) catch null else null;
    const subject = patchci.patchSubject(aa, repo.name, patch_id) catch return null;
    var summary = status.forSubject(aa, s, subject, tips) catch null;
    // no run of its own: what ran on its tip (a stack's run, the watcher's)
    if (summary == null) if (tip) |t| {
        const index = status.commitIndex(aa, s, repo.name) catch status.CommitIndex{};
        if (index.get(t)) |found| {
            summary = found;
            summary.?.label = std.fmt.allocPrint(aa, "{s} on its tip", .{found.label}) catch found.label;
        }
    };
    return .{ .summary = summary, .repo = repo.name, .id = patch_id, .back = back };
}

pub fn patchBall(arena: *std.heap.ArenaAllocator, repo_name: []const u8, patch_id: []const u8) ?Summary {
    const s = store() orelse return null;
    const aa = arena.allocator();
    return status.forSubject(aa, s, patchci.patchSubject(aa, repo_name, patch_id) catch return null, null) catch null;
}

// a stack's CI and the merge gate
pub const StackCi = struct {
    summary: ?Summary,
    run_action: []const u8 = "/ci/run/stack",
    id: []const u8,
    back: []const u8,
    // the pullfile requires green CI to merge
    required: bool = false,
    // merging is allowed by the gate
    gate_ok: bool = true,
    gate_reason: []const u8 = "",
};

pub fn stackCi(arena: *std.heap.ArenaAllocator, stack_id: []const u8, back: []const u8) ?StackCi {
    const ws = integrate.workspace orelse return null;
    const s = store() orelse return null;
    const aa = arena.allocator();
    const members = patchci.stackMembers(ws, arena, stack_id) catch &.{};
    const tips = patchci.tips(aa, members) catch null;
    var out: StackCi = .{ .summary = status.forSubject(aa, s, patchci.stackSubject(aa, stack_id) catch return null, tips) catch null, .id = stack_id, .back = back };
    if (gate.verdict(ws, arena, stack_id)) |v| {
        out.required = v.required;
        out.gate_ok = v.ok;
        out.gate_reason = v.reason;
    } else |_| {}
    return out;
}

pub fn stackBall(arena: *std.heap.ArenaAllocator, stack_id: []const u8) ?Summary {
    const s = store() orelse return null;
    const aa = arena.allocator();
    return status.forSubject(aa, s, patchci.stackSubject(aa, stack_id) catch return null, null) catch null;
}

pub fn issueRefs(arena: *std.heap.ArenaAllocator, identity: []const u8, issue_id: []const u8) ?References {
    const ws = integrate.workspace orelse return null;
    const repo = repoOf(identity) orelse return null;
    const refs = links.references(ws, arena, store(), repo, issue_id) catch return null;
    return if (refs.empty()) null else refs;
}

// a commit message as html, its issue mentions linked
pub fn linkHtml(arena: *std.heap.ArenaAllocator, identity: []const u8, text: []const u8) ?theme.vin.Str {
    const ws = integrate.workspace orelse return null;
    const repo = repoOf(identity) orelse return null;
    var resolver: links.Resolver = .{ .ws = ws, .arena = arena, .repo = repo };
    return theme.markup(links.link(&resolver, text, .html) catch return null);
}

// like linkHtml, but null unless some mention became a link
pub fn linkHtmlIfAny(arena: *std.heap.ArenaAllocator, identity: []const u8, text: []const u8) ?theme.vin.Str {
    if (std.mem.indexOfScalar(u8, text, '#') == null) return null;
    const html = linkHtml(arena, identity, text) orelse return null;
    return if (std.mem.indexOf(u8, html.bytes, "<a href=") != null) html else null;
}

// markdown with its issue mentions as links
pub fn linkMarkdown(arena: *std.heap.ArenaAllocator, identity: []const u8, text: []const u8) []const u8 {
    const ws = integrate.workspace orelse return text;
    const repo = repoOf(identity) orelse return text;
    var resolver: links.Resolver = .{ .ws = ws, .arena = arena, .repo = repo };
    return links.link(&resolver, text, .markdown) catch text;
}

// a stack's description (in the events repo) with mentions of any repo's issues linked
pub fn linkStackMarkdown(arena: *std.heap.ArenaAllocator, text: []const u8) []const u8 {
    const ws = integrate.workspace orelse return text;
    const events = ws.events orelse return text;
    var resolver: links.Resolver = .{ .ws = ws, .arena = arena, .repo = events, .everywhere = true };
    return links.link(&resolver, text, .markdown) catch text;
}
