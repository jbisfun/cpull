// CI for patches and stacks: cpull resolves a patch's or a stack's members
// (each member patch's source branch and its tip now) and asks idlci to run
// them, `POST /api/runs {subject, members, requested_by}` (theme
// docs/workspace-tools.md §5). idlci picks the member repos' idl projects,
// checks everything out in a work tree of its own and queues build + test.
// A subject is "patch:<repo>:<patch id>" or "stack:<stack id>"; its jobs'
// status comes back through idlci's /api/status/subject.
const std = @import("std");
const evt = @import("../event.zig");
const ws_mod = @import("../workspace.zig");
const forge = @import("../forge.zig");
const tools = @import("tools.zig");

const Workspace = ws_mod.Workspace;
const Repo = ws_mod.Repo;

pub const Member = struct {
    repo: []const u8,
    patch_id: []const u8,
    branch: []const u8,
    // the source branch's tip now
    oid: []const u8,
};

pub fn patchSubject(a: std.mem.Allocator, repo: []const u8, patch_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "patch:{s}:{s}", .{ repo, patch_id });
}

pub fn stackSubject(a: std.mem.Allocator, stack_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "stack:{s}", .{stack_id});
}

// a patch's source branch and its tip
pub fn patchMember(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, patch: forge.PatchInfo) !Member {
    const branch = patch.source_branch orelse return error.PatchFromFork;
    const oid = forge.branchTip(ws.io, arena.allocator(), repo.path, branch) orelse return error.SourceBranchMissing;
    return .{ .repo = repo.name, .patch_id = patch.id, .branch = branch, .oid = oid };
}

// a stack's members with their source tips (members that can't be read are skipped)
pub fn stackMembers(ws: *const Workspace, arena: *std.heap.ArenaAllocator, stack_id: []const u8) ![]Member {
    const found = try ws_mod.readStack(ws, arena, stack_id);
    var out: std.ArrayList(Member) = .empty;
    var iter = evt.Stack.memberIterator(found.record.event.members);
    while (try iter.next()) |m| {
        const repo = ws.byName(m.repo) orelse continue;
        const patch = forge.findPatch(ws, arena, repo, m.patch_id) catch continue;
        const member = patchMember(ws, arena, repo, patch) catch continue;
        try out.append(arena.allocator(), member);
    }
    return out.items;
}

// "<repo> <oid>" per member: what a subject's jobs must have checked out to be current
pub fn tips(a: std.mem.Allocator, members: []const Member) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (members, 0..) |m, i| {
        if (i > 0) try out.append(a, '\n');
        try out.print(a, "{s} {s}", .{ m.repo, m.oid });
    }
    return out.items;
}

pub const Queued = struct {
    subject: []const u8,
    // idlci's answer: {subject, checkout, jobs: [Enqueued]}
    response: std.json.Value,
    // jobs idlci queued anew (not deduplicated)
    fresh: usize,
    total: usize,
};

pub fn queuePatch(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo_name: []const u8, prefix: []const u8, by: []const u8, msg: *[]const u8) !Queued {
    const aa = arena.allocator();
    const repo = ws.byName(std.mem.trimEnd(u8, repo_name, "/")) orelse {
        msg.* = try std.fmt.allocPrint(aa, "no repo {s} in the pullfile", .{repo_name});
        return error.BadRequest;
    };
    const patch = forge.findPatch(ws, arena, repo, prefix) catch |e| {
        msg.* = try std.fmt.allocPrint(aa, "patch {s} in {s}: {t}", .{ prefix, repo_name, e });
        return error.BadRequest;
    };
    const member = patchMember(ws, arena, repo, patch) catch |e| {
        msg.* = try std.fmt.allocPrint(aa, "patch {s}: {t}", .{ patch.id[0..8], e });
        return error.BadRequest;
    };
    return queue(ws, arena, try patchSubject(aa, repo.name, patch.id), &.{member}, by, msg);
}

pub fn queueStack(ws: *const Workspace, arena: *std.heap.ArenaAllocator, prefix: []const u8, by: []const u8, msg: *[]const u8) !Queued {
    const aa = arena.allocator();
    const found = ws_mod.readStack(ws, arena, prefix) catch |e| {
        msg.* = try std.fmt.allocPrint(aa, "stack {s}: {t}", .{ prefix, e });
        return error.BadRequest;
    };
    const members = try stackMembers(ws, arena, &found.id);
    if (members.len == 0) {
        msg.* = "none of the stack's patches has a source branch to check out";
        return error.BadRequest;
    }
    return queue(ws, arena, try stackSubject(aa, &found.id), members, by, msg);
}

fn queue(ws: *const Workspace, arena: *std.heap.ArenaAllocator, subject: []const u8, members: []const Member, by: []const u8, msg: *[]const u8) !Queued {
    const aa = arena.allocator();
    var client = tools.connectIdlci(ws.io, aa, ws.root) orelse {
        msg.* = "idlci isn't running (start the idlci job: pull launchctl start idlci)";
        return error.CiNotReachable;
    };
    defer client.deinit();
    const body = try std.json.Stringify.valueAlloc(aa, .{ .subject = subject, .members = members, .requested_by = by }, .{});
    const res = client.post("/api/runs", body) catch |e| {
        msg.* = if (client.last_error.len > 0) client.last_error else @errorName(e);
        return error.BadRequest;
    };
    var fresh: usize = 0;
    var total: usize = 0;
    if (res == .object) if (res.object.get("jobs")) |jobs| if (jobs == .array) for (jobs.array.items) |j| {
        total += 1;
        const dedup = if (j == .object) if (j.object.get("deduplicated")) |d| d == .bool and d.bool else false else false;
        if (!dedup) fresh += 1;
    };
    return .{ .subject = subject, .response = res, .fresh = fresh, .total = total };
}

test tips {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("core aaa\nlib bbb", try tips(a, &.{ .{ .repo = "core", .patch_id = "1", .branch = "x", .oid = "aaa" }, .{ .repo = "lib", .patch_id = "2", .branch = "y", .oid = "bbb" } }));
    try std.testing.expectEqualStrings("patch:core:ab", try patchSubject(a, "core", "ab"));
}
