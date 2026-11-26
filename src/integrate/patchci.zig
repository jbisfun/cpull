// CI for patches and stacks: queue `build` and `test` of every idl project in
// a patch's repo (or in each member repo of a stack) with the patch's source
// commit checked out, in a work tree of its own (ci/work.zig). The jobs carry
// a subject ("patch:<repo>:<id>" / "stack:<id>") and the commits they check
// out, so the patch and stack pages show their latest result, and know when
// it ran on older commits than the branches now hold.
const std = @import("std");
const db = @import("../ci/db.zig");
const ci_app = @import("../ci/app.zig");
const evt = @import("../event.zig");
const ws_mod = @import("../workspace.zig");
const forge = @import("forge.zig");

const App = ci_app.App;
const Workspace = ws_mod.Workspace;
const Repo = ws_mod.Repo;

pub const Member = struct {
    repo: []const u8,
    patch_id: []const u8,
    branch: []const u8,
    // the source branch's tip now
    oid: []const u8,
};

pub const Queued = struct {
    subject: []const u8,
    checkout: []const u8,
    jobs: []const db.Enqueued,
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

pub fn queuePatch(app: *App, ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo_name: []const u8, prefix: []const u8, by: db.RequestedBy, msg: *[]const u8) !Queued {
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
    return queue(app, ws, arena, try patchSubject(aa, repo.name, patch.id), &.{member}, by, msg);
}

pub fn queueStack(app: *App, ws: *const Workspace, arena: *std.heap.ArenaAllocator, prefix: []const u8, by: db.RequestedBy, msg: *[]const u8) !Queued {
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
    return queue(app, ws, arena, try stackSubject(aa, &found.id), members, by, msg);
}

// the pullfile repo holding an absolute dir
fn repoHolding(ws: *const Workspace, dir: []const u8) ?Repo {
    var best: ?Repo = null;
    for (ws.repos) |r| {
        const inside = std.mem.eql(u8, dir, r.path) or (std.mem.startsWith(u8, dir, r.path) and dir.len > r.path.len and dir[r.path.len] == '/');
        if (inside and (best == null or r.path.len > best.?.path.len)) best = r;
    }
    return best;
}

fn queue(app: *App, ws: *const Workspace, arena: *std.heap.ArenaAllocator, subject: []const u8, members: []const Member, by: db.RequestedBy, msg: *[]const u8) !Queued {
    const aa = arena.allocator();
    // the idl projects of the member repos
    var selected: std.ArrayList(struct { path: []const u8, dir: []const u8, member: Member }) = .empty;
    for (try app.projectList(aa)) |p| {
        const repo = app.repoOf(p.dir) orelse continue;
        for (members) |m| if (std.mem.eql(u8, m.repo, repo)) {
            try selected.append(aa, .{ .path = p.path, .dir = p.dir, .member = m });
        };
    }
    if (selected.items.len == 0) {
        var names: std.ArrayList([]const u8) = .empty;
        for (members) |m| try names.append(aa, m.repo);
        msg.* = try std.fmt.allocPrint(aa, "no idl projects in {s}, so there is nothing to build", .{try std.mem.join(aa, ", ", names.items)});
        return error.NoProjects;
    }
    // what to check out: the members at their source tips, the repos their
    // targets live in (sibling repos) at the workspace's current commits
    var checkout: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (members) |m| try checkout.put(aa, m.repo, m.oid);
    for (selected.items) |p| {
        var tmsg: []const u8 = "";
        const targets = app.targets(aa, .{ .path = p.path, .dir = p.dir }, &tmsg) catch continue;
        for (targets) |t| {
            const dir = try std.fs.path.resolve(aa, &.{ p.dir, t.dir });
            const repo = repoHolding(ws, dir) orelse continue;
            if (checkout.contains(repo.name)) continue;
            const oid = forge.headOid(ws.io, aa, repo.path) orelse continue;
            try checkout.put(aa, repo.name, oid);
        }
    }
    const Entry = struct { repo: []const u8, oid: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var it = checkout.iterator();
    while (it.next()) |e| try entries.append(aa, .{ .repo = e.key_ptr.*, .oid = e.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.repo, y.repo);
        }
    }.lt);
    var text: std.ArrayList(u8) = .empty;
    for (entries.items, 0..) |e, i| {
        if (i > 0) try text.append(aa, '\n');
        try text.print(aa, "{s} {s}", .{ e.repo, e.oid });
    }

    var jobs: std.ArrayList(db.Enqueued) = .empty;
    for (selected.items) |p| {
        for ([_]db.Command{ .build, .@"test" }) |command| {
            const enq = try app.enqueueWith(aa, .{
                .project = p.path,
                .command = command,
                .requested_by = by,
                .subject = subject,
                .checkout = text.items,
            }, .{ .repo = p.member.repo, .branch = p.member.branch, .head = p.member.oid[0..@min(7, p.member.oid.len)] }, msg);
            try jobs.append(aa, enq);
        }
    }
    return .{ .subject = subject, .checkout = text.items, .jobs = jobs.items };
}
