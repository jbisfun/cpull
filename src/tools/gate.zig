// the merge gate: with the pullfile's `cpull.require_ci = true`, a stack
// merges (web or `cpull stack merge` / `pull cpull merge`) only when the CI
// is green for every member repo that has idl projects, at the commits its
// branch holds now: the stack's own latest jobs ("Run CI" on the stack page,
// `idlci stack ID`), or else each member patch's. `--force` (the web form's
// "merge anyway") skips it. The logic is cpull's; the data is idlci's
// (GET /api/projects and /api/status/subject). With idlci down and the gate
// on, nothing merges: "CI not reachable". Installed into workspace.zig's
// `merge_gate` hook by tools.install / installCli.
const std = @import("std");
const ws_mod = @import("../workspace.zig");
const tools = @import("tools.zig");
const idlci = @import("idlci.zig");
const runs = @import("runs.zig");
const status = @import("status.zig");

const Workspace = ws_mod.Workspace;

pub const Verdict = struct {
    // the gate is on
    required: bool,
    // merging is allowed (always, when the gate is off)
    ok: bool,
    // why not, or what was found
    reason: []const u8,
};

// workspace.MergeGate: the reason to refuse, or null to merge
pub fn check(ws: *const Workspace, arena: *std.heap.ArenaAllocator, stack_id: []const u8) anyerror!?[]const u8 {
    if (!tools.config(ws.io, ws.gpa, ws.root).require_ci) return null;
    const v = try verdict(ws, arena, stack_id);
    if (v.ok) return null;
    return try std.fmt.allocPrint(arena.allocator(), "the pullfile requires green CI to merge (cpull.require_ci): {s}. Run CI on the stack page or with `idlci stack {s}`, or merge with --force", .{ v.reason, stack_id[0..@min(stack_id.len, 8)] });
}

pub fn verdict(ws: *const Workspace, arena: *std.heap.ArenaAllocator, stack_id: []const u8) !Verdict {
    const aa = arena.allocator();
    const cfg = tools.config(ws.io, ws.gpa, ws.root);
    var client = tools.connectIdlci(ws.io, aa, ws.root) orelse
        return .{ .required = cfg.require_ci, .ok = !cfg.require_ci, .reason = "CI not reachable (idlci isn't running)" };
    defer client.deinit();
    return verdictWith(&client, ws, arena, stack_id, cfg.require_ci);
}

pub fn verdictWith(client: *idlci.Client, ws: *const Workspace, arena: *std.heap.ArenaAllocator, stack_id: []const u8, required: bool) !Verdict {
    const aa = arena.allocator();
    const found = try ws_mod.readStack(ws, arena, stack_id);
    const members = try runs.stackMembers(ws, arena, &found.id);
    const with_projects = reposWithProjects(client) catch
        return .{ .required = required, .ok = !required, .reason = try std.fmt.allocPrint(aa, "CI not reachable ({s})", .{client.last_error}) };
    var gated: std.ArrayList(runs.Member) = .empty;
    for (members) |m| for (with_projects) |r| if (std.mem.eql(u8, r, m.repo)) {
        try gated.append(aa, m);
        break;
    };
    if (gated.items.len == 0) return .{ .required = required, .ok = true, .reason = "no member repo has idl projects" };

    // the stack's own run covers every gated member at once
    const stack_ci = forSubject(client, try runs.stackSubject(aa, &found.id), try runs.tips(aa, gated.items)) catch
        return .{ .required = required, .ok = !required, .reason = try std.fmt.allocPrint(aa, "CI not reachable ({s})", .{client.last_error}) };
    if (stack_ci) |s| if (s.green) return .{ .required = required, .ok = true, .reason = s.label };
    // else every gated member's own patch run
    var why: ?[]const u8 = null;
    for (gated.items) |m| {
        const s = forSubject(client, try runs.patchSubject(aa, m.repo, m.patch_id), try runs.tips(aa, &.{m})) catch null;
        if (s != null and s.?.green) continue;
        why = if (s) |x| try std.fmt.allocPrint(aa, "{s}: {s}", .{ m.repo, x.label }) else try std.fmt.allocPrint(aa, "no CI has run on {s} {s} yet", .{ m.repo, m.branch });
        break;
    }
    const reason = why orelse return .{ .required = required, .ok = true, .reason = "every member's own CI passed" };
    // the stack's run says more than a member's missing one
    return .{ .required = required, .ok = !required, .reason = if (stack_ci) |s| try std.fmt.allocPrint(aa, "the stack's {s}", .{s.label}) else reason };
}

// idlci's summary of a subject's latest jobs, stale against `tips`
pub fn forSubject(client: *idlci.Client, subject: []const u8, tips: ?[]const u8) !?status.Summary {
    const a = client.a;
    const path = if (tips) |t|
        try std.fmt.allocPrint(a, "/api/status/subject?subject={s}&tips={s}", .{ try idlci.queryEscape(a, subject), try idlci.queryEscape(a, t) })
    else
        try std.fmt.allocPrint(a, "/api/status/subject?subject={s}", .{try idlci.queryEscape(a, subject)});
    return status.parseSummary(client, try client.get(path));
}

// the pullfile repos holding an idl project (idlci's ProjectView `repo`)
pub fn reposWithProjects(client: *idlci.Client) ![]const []const u8 {
    const v = try client.get("/api/projects");
    var out: std.ArrayList([]const u8) = .empty;
    if (v != .array) return out.items;
    for (v.array.items) |p| if (p == .object) {
        const repo = p.object.get("repo") orelse blk: {
            const g = p.object.get("git") orelse continue;
            if (g != .object) continue;
            break :blk g.object.get("repo") orelse continue;
        };
        if (repo == .string) try out.append(client.a, repo.string);
    };
    return out.items;
}
