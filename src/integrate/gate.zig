// the merge gate: with the pullfile's `cpull.require_ci = true`, a stack
// merges (web or `cpull stack merge` / `pull cpull merge`) only when the CI
// is green for every member repo that has idl projects, at the commits its
// branch holds now: the stack's own latest jobs ("Run CI" on the stack page,
// `cpull ci stack ID`), or else each member patch's. `--force` (the web
// form's "merge anyway") skips it. installed into workspace.zig's
// `merge_gate` hook by integrate.install / installCli.
const std = @import("std");
const db = @import("../ci/db.zig");
const projects = @import("../ci/projects.zig");
const ws_mod = @import("../workspace.zig");
const integrate = @import("integrate.zig");
const patchci = @import("patchci.zig");
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
    if (!integrate.config(ws.io, ws.gpa, ws.root).require_ci) return null;
    const v = try verdict(ws, arena, stack_id);
    if (v.ok) return null;
    return try std.fmt.allocPrint(arena.allocator(), "the pullfile requires green CI to merge (cpull.require_ci): {s}. Run CI on the stack page or with `cpull ci stack {s}`, or merge with --force", .{ v.reason, stack_id[0..@min(stack_id.len, 8)] });
}

pub fn verdict(ws: *const Workspace, arena: *std.heap.ArenaAllocator, stack_id: []const u8) !Verdict {
    const aa = arena.allocator();
    const cfg = integrate.config(ws.io, ws.gpa, ws.root);
    const found = try ws_mod.readStack(ws, arena, stack_id);
    const members = try patchci.stackMembers(ws, arena, &found.id);
    const with_projects = try reposWithProjects(ws, aa);
    var gated: std.ArrayList(patchci.Member) = .empty;
    for (members) |m| for (with_projects) |r| if (std.mem.eql(u8, r, m.repo)) {
        try gated.append(aa, m);
        break;
    };
    if (gated.items.len == 0) return .{ .required = cfg.require_ci, .ok = true, .reason = "no member repo has idl projects" };

    var opened: ?*db.Store = null;
    defer if (opened) |s| s.close(ws.gpa);
    const store = if (integrate.app) |app| app.store else blk: {
        opened = try db.Store.open(ws.io, ws.gpa, try db.dataDir(aa, ws.root), null);
        break :blk opened.?;
    };

    // the stack's own run covers every gated member at once
    const stack_ci = try status.forSubject(aa, store, try patchci.stackSubject(aa, &found.id), try patchci.tips(aa, gated.items));
    if (stack_ci) |s| if (s.green) return .{ .required = cfg.require_ci, .ok = true, .reason = s.label };
    // else every gated member's own patch run
    var why: ?[]const u8 = null;
    for (gated.items) |m| {
        const subject = try patchci.patchSubject(aa, m.repo, m.patch_id);
        const s = try status.forSubject(aa, store, subject, try patchci.tips(aa, &.{m}));
        if (s != null and s.?.green) continue;
        why = if (s) |x| try std.fmt.allocPrint(aa, "{s}: {s}", .{ m.repo, x.label }) else try std.fmt.allocPrint(aa, "no CI has run on {s} {s} yet", .{ m.repo, m.branch });
        break;
    }
    const reason = why orelse return .{ .required = cfg.require_ci, .ok = true, .reason = "every member's own CI passed" };
    // the stack's run says more than a member's missing one
    return .{ .required = cfg.require_ci, .ok = !cfg.require_ci, .reason = if (stack_ci) |s| try std.fmt.allocPrint(aa, "the stack's {s}", .{s.label}) else reason };
}

// the pullfile repos holding an idl project
fn reposWithProjects(ws: *const Workspace, aa: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (integrate.app) |app| {
        for (try app.projectList(aa)) |p| if (app.repoOf(p.dir)) |r| try out.append(aa, r);
    } else {
        const root = std.Io.Dir.cwd().realPathFileAlloc(ws.io, ws.root, aa) catch ws.root;
        for (try projects.discover(ws.io, aa, root)) |p| if (projects.repoName(ws.io, aa, root, p.dir)) |r| try out.append(aa, r);
    }
    return out.items;
}
