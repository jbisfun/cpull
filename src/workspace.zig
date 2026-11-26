// workspace mode: cpull over a pull workspace (github.com/jbisfun/pull), a
// pullfile.plist listing repos that move together. the workspace is a stack of
// repos: an events repo (the workspace root's own repo, or the pullfile
// `cpull` section's `events` repo) holding the workspace's issues and its
// stacks, and every pullfile repo (nested ones as "group/name") with its own
// issues and patches. a stack is a change across repos: one ordinary patch per
// member repo, landed together. cpull merges the members; pull records the new
// pins, since it owns the pullfile, its commits and their signatures.
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const mrg = xit.merge;
const hash = xit.hash;
const evt = @import("event.zig");
const pch = @import("patch.zig");
const ui = @import("ui.zig");
const pullfile = @import("pullfile.zig");
const cmd = @import("command.zig");

pub const Repo = struct {
    // the pullfile name ("" for the workspace root's own repo)
    name: []const u8,
    // the cpull repo name: "/" becomes "."
    key: []const u8,
    // the pullfile branch, which the repo's patches target
    branch: []const u8,
    pin: ?[]const u8 = null,
    path: []const u8,
};

pub const root_key = "workspace";

// the cpull repo name a pullfile repo goes by, here and when its workspace is
// pushed to a server: cpull names can't hold "/", so a nested "group/name" is
// "group.name"
pub fn keyOf(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const key = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, key, '/', '.');
    return key;
}

pub const Workspace = struct {
    io: std.Io,
    // thread-safe, for transient work
    gpa: std.mem.Allocator,
    root: []const u8,
    // the owner every repo identity carries
    name: []const u8,
    repos: []const Repo,
    events: ?Repo,
    global_config_path: ?[]const u8,
    host: ui.WorkspaceHost = undefined,
    // the `pull` that records pins after a merge
    pull_exe: []const u8 = "pull",

    // everything is allocated in `arena`, which must outlive the workspace
    pub fn load(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: []const u8, global_config_path: ?[]const u8) !*Workspace {
        const pf = try pullfile.load(io, arena, root);
        const base = std.Io.Dir.path.basename(root);
        const name = if (evt.User.validateName(base)) base else |_| "workspace";
        var repos: std.ArrayList(Repo) = .empty;
        for (pf.repos) |r| {
            if (!evt.Stack.repoNameValid(r.name)) return error.InvalidRepoName;
            const key = try keyOf(arena, r.name);
            for (repos.items) |other| if (std.mem.eql(u8, other.key, key)) return error.RepoNameCollision;
            try repos.append(arena, .{ .name = r.name, .key = key, .branch = r.branch, .pin = r.commit, .path = try std.Io.Dir.path.join(arena, &.{ root, r.name }) });
        }
        const events: ?Repo = if (pf.events_repo) |events_name| blk: {
            for (repos.items) |r| if (std.mem.eql(u8, r.name, events_name)) break :blk r;
            return error.EventsRepoNotFound;
        } else if (isGitDir(io, arena, root)) .{ .name = "", .key = root_key, .branch = "", .path = root } else null;
        if (events) |e| if (e.name.len == 0) for (repos.items) |r| if (std.mem.eql(u8, r.key, root_key)) return error.RepoNameCollision;
        // repos still on haxy's events branch move to cpull's
        for (repos.items) |r| evt.adoptLegacyAt(io, gpa, r.path);
        if (events) |e| if (e.name.len == 0) evt.adoptLegacyAt(io, gpa, e.path);
        const self = try arena.create(Workspace);
        self.* = .{ .io = io, .gpa = gpa, .root = root, .name = name, .repos = repos.items, .events = events, .global_config_path = global_config_path };
        self.host = .{ .ctx = self, .page = hostPage, .source = hostSource, .merge = hostMerge, .repos = hostRepos, .merge_patch = hostMergePatch };
        return self;
    }

    pub fn identity(self: *const Workspace, arena: std.mem.Allocator, repo: Repo) ![]const u8 {
        return arena.print("{s}:{s}", .{ self.name, repo.key });
    }

    pub fn source(self: *const Workspace, repo: Repo) ui.RepoSource {
        return .{ .path = repo.path, .repo_kind = .git, .global_config_path = self.global_config_path, .pull_identity = true };
    }

    pub fn byName(self: *const Workspace, name: []const u8) ?Repo {
        for (self.repos) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    // the repo an "<owner>:<key>" identity names, the events repo included
    pub fn byIdentity(self: *const Workspace, id: []const u8) ?Repo {
        const parsed = evt.parseOwnerRepoPath(id) orelse return null;
        if (!std.mem.eql(u8, parsed.owner, self.name)) return null;
        if (self.events) |e| if (std.mem.eql(u8, e.key, parsed.name)) return e;
        for (self.repos) |r| if (std.mem.eql(u8, r.key, parsed.name)) return r;
        return null;
    }
};

fn isGitDir(io: std.Io, arena: std.mem.Allocator, dir: []const u8) bool {
    const path = std.Io.Dir.path.join(arena, &.{ dir, ".git" }) catch return false;
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

// the workspace a cpull started in `cwd` views, or null for plain local mode:
// the nearest pullfile, unless a repo nested inside it is nearer
pub fn detect(io: std.Io, arena: std.mem.Allocator, cwd: []const u8, nearest_repo: ?[]const u8) !?[]const u8 {
    const root = (try pullfile.findRoot(io, arena, cwd)) orelse return null;
    if (nearest_repo) |repo| if (repo.len > root.len) return null;
    return root;
}

//
// stacks
//

pub const NewMember = struct {
    // the pullfile repo
    repo: []const u8,
    source_branch: []const u8,
    // defaults to the pullfile branch
    target_branch: ?[]const u8 = null,
};

pub const Created = struct {
    id: [evt.event_id_size * 2]u8,
    members: []const evt.Stack.Member,
};

// open one patch per member and the stack naming them
pub fn createStack(ws: *const Workspace, arena: std.mem.Allocator, title: []const u8, description: []const u8, labels: []const u8, members: []const NewMember) !Created {
    if (!evt.Stack.fieldsValid(title, labels)) return error.InvalidFields;
    const events = ws.events orelse return error.NoEventsRepo;
    if (members.len == 0) return error.EmptyStack;
    for (members, 0..) |m, i| for (members[i + 1 ..]) |other| if (std.mem.eql(u8, m.repo, other.repo)) return error.DuplicateStackMember;

    var created: std.ArrayList(evt.Stack.Member) = .empty;
    for (members) |m| {
        const repo = ws.byName(m.repo) orelse return error.RepoNotFound;
        var id_bytes: [evt.event_id_size]u8 = undefined;
        ws.io.random(&id_bytes);
        const id = std.fmt.bytesToHex(id_bytes, .lower);
        try withRepo(ws, repo, true, struct {
            fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
                try pch.writeBranchPatch(.local, .git, opts, w.io, w.gpa, r, args.id, .{
                    .title = args.title,
                    .description = args.description,
                    .labels = args.labels,
                    .source_branch = args.source,
                    .target_branch = args.target,
                }, null, author);
            }
        }.run, .{ .id = id, .title = title, .description = description, .labels = labels, .source = m.source_branch, .target = m.target_branch orelse repo.branch });
        try created.append(arena, .{ .repo = repo.name, .patch_id = try arena.dupe(u8, &id) });
    }

    var stack_id: [evt.event_id_size]u8 = undefined;
    ws.io.random(&stack_id);
    const stack: evt.Stack = .{ .title = title, .description = description, .labels = labels, .members = try evt.Stack.formatMembers(arena, created.items) };
    try withRepo(ws, events, true, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            try evt.Stack.write(.local, .git, opts, w.io, w.gpa, r, args.id, args.stack, author);
        }
    }.run, .{ .id = &stack_id, .stack = stack });
    return .{ .id = std.fmt.bytesToHex(stack_id, .lower), .members = created.items };
}

// the stack `id` (a unique prefix will do) names, read from the events repo
pub fn readStack(ws: *const Workspace, arena: *std.heap.ArenaAllocator, id: []const u8) !evt.Stack.WithId {
    for (try listStacks(ws, arena)) |stack| {
        if (std.mem.startsWith(u8, &stack.id, id) and id.len > 0) return stack;
    }
    return error.StackNotFound;
}

pub fn listStacks(ws: *const Workspace, arena: *std.heap.ArenaAllocator) ![]const evt.Stack.WithId {
    const events = ws.events orelse return &.{};
    var out: []const evt.Stack.WithId = &.{};
    try withRepo(ws, events, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            args.out.* = try evt.Stack.list(evt.EventDB(opts.hash), opts.hash, moment, args.arena);
        }
    }.run, .{ .out = &out, .arena = arena });
    return out;
}

pub const Pin = struct { repo: []const u8, oid: []const u8 };

// merge every member patch into its target branch, all or nothing: each one is
// checked first, then merged (a fast-forward where it can be) and marked
// merged, and the stack is marked merged with the commits to pin
pub fn mergeStack(ws: *const Workspace, arena: *std.heap.ArenaAllocator, id: []const u8) ![]const Pin {
    const events = ws.events orelse return error.NoEventsRepo;
    const found = try readStack(ws, arena, id);
    var stack = found.record.event;
    switch (stack.status) {
        .open => {},
        .closed => return error.StackClosed,
        .merged => |merged| return parsePins(arena.allocator(), merged.pins),
    }
    if (found.conflicted_fields.len > 0) return error.StackConflicted;

    // every member must merge before any does
    var members: std.ArrayList(evt.Stack.Member) = .empty;
    var iter = evt.Stack.memberIterator(stack.members);
    while (try iter.next()) |member| {
        const repo = ws.byName(member.repo) orelse return error.MemberRepoNotFound;
        const check = try memberMerge(ws, arena, repo, member.patch_id, .check);
        switch (check.outcome) {
            .fast_forward, .clean, .nothing, .merged => {},
            .conflict => return error.MergeConflict,
            .missing => return error.PatchNotFound,
            .closed => return error.PatchClosed,
            .checked_out => return error.TargetBranchCheckedOut,
            .out_of_date => return error.PatchOutOfDate,
        }
        try members.append(arena.allocator(), member);
    }

    var pins: std.ArrayList(Pin) = .empty;
    var lines: std.ArrayList(u8) = .empty;
    for (members.items) |member| {
        const repo = ws.byName(member.repo).?;
        const merged = try memberMerge(ws, arena, repo, member.patch_id, .merge);
        const oid = merged.target_oid orelse return error.InvalidTargetBranch;
        try pins.append(arena.allocator(), .{ .repo = member.repo, .oid = oid });
        if (lines.items.len > 0) try lines.append(arena.allocator(), '\n');
        try lines.print(arena.allocator(), "{s} {s}", .{ member.repo, oid });
    }

    stack.status = .{ .merged = .{ .pins = lines.items } };
    const id_bytes = try evt.parseEventId(&found.id);
    try withRepo(ws, events, true, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            try evt.Stack.write(.local, .git, opts, w.io, w.gpa, r, args.id, args.stack, author);
        }
    }.run, .{ .id = &id_bytes, .stack = stack });
    return pins.items;
}

fn parsePins(arena: std.mem.Allocator, text: []const u8) ![]const Pin {
    var pins: std.ArrayList(Pin) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        try pins.append(arena, .{ .repo = line[0..space], .oid = line[space + 1 ..] });
    }
    return pins.items;
}

pub const Outcome = enum { fast_forward, clean, nothing, conflict, merged, missing, closed, checked_out, out_of_date };

pub const MemberState = struct {
    outcome: Outcome,
    status: []const u8 = "missing",
    title: []const u8 = "",
    source_branch: []const u8 = "",
    target_branch: []const u8 = "",
    // the target tip: before a check, after a merge
    target_oid: ?[]const u8 = null,

    fn setOutcome(self: *MemberState, outcome: Outcome) void {
        self.outcome = outcome;
    }
};

// check (a dry run) or perform the merge of one member patch
pub fn memberMerge(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, patch_id: []const u8, mode: enum { check, merge }) !MemberState {
    var state: MemberState = .{ .outcome = .missing };
    const id = evt.parseEventId(patch_id) catch return state;
    withRepo(ws, repo, mode == .merge, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            try mergeInRepo(opts, w, r, author, args.arena, args.id, args.merge, args.state);
        }
    }.run, .{ .arena = arena, .id = &id, .merge = mode == .merge, .state = &state }) catch |err| switch (err) {
        error.RepoNotFound, error.FileNotFound => return state,
        else => |e| return e,
    };
    return state;
}

fn mergeInRepo(
    comptime opts: rp.RepoOpts(.git),
    ws: *const Workspace,
    repo: *rp.Repo(.git, opts),
    author: evt.CommitAuthor,
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
    merge: bool,
    out: *MemberState,
) !void {
    const io = ws.io;
    const gpa = ws.gpa;
    const aa = arena.allocator();
    // bring the events and the patch's revision up to date with its branch
    try evt.consume(.local, .repo, .git, opts, io, gpa, repo, evt.events_ref, &.{});
    try pch.refreshBranches(.local, .git, opts, io, gpa, repo, null);
    const record = (try evt.readFromRepo(evt.Patch, .git, opts, io, gpa, arena, repo, id)) orelse return;
    if (record.removed) return;
    var patch = record.event;
    out.title = patch.title;
    out.source_branch = patch.source_branch orelse "";
    out.target_branch = patch.target_branch;
    out.status = @tagName(patch.status.kind());
    const target_ref: rf.Ref = .{ .kind = .head, .name = patch.target_branch };
    const before = (try repo.readRef(io, target_ref)) orelse return;
    out.target_oid = try aa.dupe(u8, &before);
    switch (patch.status) {
        .open => {},
        .closed => return out.setOutcome(.closed),
        .merged => return out.setOutcome(.merged),
    }
    const revision = patch.revision orelse return out.setOutcome(.out_of_date);
    if (patch.source_branch) |branch| {
        const tip = (try repo.readRef(io, .{ .kind = .head, .name = branch })) orelse return out.setOutcome(.out_of_date);
        if (!std.mem.eql(u8, &tip, revision.source_oid)) return out.setOutcome(.out_of_date);
    }
    // the merge moves the target ref without touching the work tree, so a
    // checked-out target would be left behind
    var head_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
    if (repo.head(io, &head_buffer)) |head| switch (head) {
        .ref => |ref| if (std.mem.eql(u8, ref.name, patch.target_branch)) return out.setOutcome(.checked_out),
        .oid => {},
    } else |_| {}

    var source_oid: [hash.hexLen(opts.hash)]u8 = undefined;
    if (revision.source_oid.len != source_oid.len) return out.setOutcome(.out_of_date);
    @memcpy(&source_oid, revision.source_oid);
    const identity = try aa.print("{s} <{s}>", .{ author.name, author.email });
    const timestamp: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const state = rp.Repo(.git, opts).State(.read_write){ .core = &repo.core, .extra = .{} };
    {
        var result = try mrg.Merge(.git, opts).init(state, io, gpa, .{
            .kind = .full,
            .action = .{ .new = .{ .source = &.{.{ .oid = &source_oid }} } },
            .commit_metadata = .{ .author = identity, .committer = identity, .message = patch.title, .timestamp = timestamp },
            .dry_run = !merge,
        }, target_ref, null);
        defer result.deinit();
        out.outcome = switch (result.result) {
            .conflict => .conflict,
            .fast_forward => .fast_forward,
            .nothing => .nothing,
            .success, .clean => .clean,
        };
    }
    if (!merge or out.outcome == .conflict) return;

    // record the merge as cpull's server does: a revision snapshotting what the
    // target gained, and the patch marked merged with it
    const after = (try repo.readRef(io, target_ref)) orelse return error.InvalidTargetBranch;
    out.target_oid = try aa.dupe(u8, &after);
    const snapshot = try evt.PatchRev.prepare(.git, opts, state, io, arena, &before, &after, patch.title, author, timestamp);
    patch.status = .{ .merged = .{ .revision = .source, .patchrev_id = snapshot.event.id } };
    try evt.consume(.local, .repo, .git, opts, io, gpa, repo, evt.events_ref, &.{
        snapshot.event,
        .{ .id = std.fmt.bytesToHex(id.*, .lower), .timestamp = timestamp, .author = author, .event = .{ .patch = patch } },
    });
    out.status = "merged";
}

// run `f(opts, ws, repo, author, args)` on the git repo `r` points at. the
// author, pull's identity as pinned in the repo's config, is only resolved
// (and required) when `f` writes; a reader gets a placeholder it must not use.
pub fn withRepo(ws: *const Workspace, r: Repo, write: bool, comptime f: anytype, args: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(ws.gpa);
    defer arena.deinit();
    const src = ws.source(r);
    var any_repo = try rp.AnyRepo(.git, .{}).open(ws.io, ws.gpa, src.localInitOpts());
    defer any_repo.deinit(ws.io, ws.gpa);
    const author = if (write) try ui.localAuthor(src, ws.io, ws.gpa, &arena) else ui.local_author_fallback;
    switch (any_repo) {
        inline else => |*repo| try f(repo.self_repo_opts, ws, repo, author, args),
    }
}

//
// the workspace pages
//

fn hostSource(ctx: *anyopaque, id: []const u8) ?ui.RepoSource {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    const repo = ws.byIdentity(id) orelse return null;
    return ws.source(repo);
}

fn hostPage(ctx: *anyopaque, arena: *std.heap.ArenaAllocator, session: *ui.Session, route: ui.RoutablePage.WorkspaceRoute) anyerror!ui.Workspace {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    var page = try buildPage(ws, arena, route);
    page.text = try ui.Workspace.render(arena.allocator(), page);
    if (session.data.workspace_flash) |flash| page.text = try arena.allocator().print("> {s}\n\n{s}", .{ flash, page.text });
    return page;
}

// the pullfile's repos, for the sidebar of the pages that aren't workspace pages
fn hostRepos(ctx: *anyopaque, arena: *std.heap.ArenaAllocator) anyerror![]const ui.WorkspaceRepo {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    const aa = arena.allocator();
    const out = try aa.alloc(ui.WorkspaceRepo, ws.repos.len);
    for (ws.repos, out) |repo, *row| row.* = .{ .name = repo.name, .identity = try ws.identity(aa, repo) };
    return out;
}

// merge one patch into its target branch, the way a stack merges each member
fn hostMergePatch(ctx: *anyopaque, arena: *std.heap.ArenaAllocator, identity: []const u8, patch_id: []const u8) anyerror![]const u8 {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    const repo = ws.byIdentity(identity) orelse return error.RepoNotFound;
    const aa = arena.allocator();
    const check = try memberMerge(ws, arena, repo, patch_id, .check);
    switch (check.outcome) {
        .fast_forward, .clean, .nothing => {},
        .merged => return "This patch is already merged.",
        .missing => return "There is no such patch.",
        .closed => return "This patch is closed; reopen it to merge it.",
        .conflict => return aa.print("Not merged: the patch conflicts with {s}.", .{check.target_branch}),
        .checked_out => return aa.print("Not merged: {s} is checked out in the repo, and a merge here would leave its work tree behind.", .{check.target_branch}),
        .out_of_date => return "Not merged: the patch's revision is out of date with its source branch.",
    }
    const merged = try memberMerge(ws, arena, repo, patch_id, .merge);
    return aa.print("Merged into {s} ({s}).", .{ merged.target_branch, @tagName(check.outcome) });
}

// merge a stack and have pull record its pins
fn hostMerge(ctx: *anyopaque, arena: *std.heap.ArenaAllocator, id: []const u8) anyerror![]const u8 {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    const pins = try mergeStack(ws, arena, id);
    const aa = arena.allocator();
    const result = std.process.run(aa, ws.io, .{ .argv = &.{ ws.pull_exe, "cpull", "pin", id }, .cwd = .{ .path = ws.root } }) catch |err|
        return aa.print("merged {d} repo{s}; pins not recorded: running pull: {s}", .{ pins.len, if (pins.len == 1) "" else "s", @errorName(err) });
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const output = std.mem.trim(u8, if (ok) result.stdout else result.stderr, " \r\n");
    if (!ok) return aa.print("merged {d} repo{s}; pull cpull pin failed: {s}", .{ pins.len, if (pins.len == 1) "" else "s", output });
    return aa.print("merged {d} repo{s} and pinned them: {s}", .{ pins.len, if (pins.len == 1) "" else "s", output });
}

pub fn buildPage(ws: *Workspace, arena: *std.heap.ArenaAllocator, route: ui.RoutablePage.WorkspaceRoute) !ui.Workspace {
    const aa = arena.allocator();
    // pins move under us (pull writes them), so the pullfile is read per page
    const pf = pullfile.load(ws.io, aa, ws.root) catch null;
    var page: ui.Workspace = .{ .name = ws.name, .view = route.view };
    if (ws.events) |e| page.events_identity = try ws.identity(aa, e);

    var repos: std.ArrayList(ui.Workspace.RepoRow) = .empty;
    var issues: std.ArrayList(ui.Workspace.IssueRow) = .empty;
    var patches: std.ArrayList(ui.Workspace.PatchRow) = .empty;
    // every view reads each repo's head and counts (the stacks views' json
    // reports `cloned` too); home lists the open issues and patches as well
    const list_issues = route.view == .issues or route.view == .home;
    const list_patches = route.view == .patches or route.view == .home;
    // the root repo, when it's the events repo, isn't one of the pullfile's
    const root_events: ?Repo = if (ws.events) |e| if (e.name.len == 0) e else null else null;
    const all = if (root_events) |e| try std.mem.concat(aa, Repo, &.{ &.{e}, ws.repos }) else ws.repos;
    for (all) |repo| {
        const identity = try ws.identity(aa, repo);
        const pin = if (pf) |p| blk: {
            for (p.repos) |r| if (std.mem.eql(u8, r.name, repo.name)) break :blk r.commit;
            break :blk repo.pin;
        } else repo.pin;
        var row: ui.Workspace.RepoRow = .{
            .name = if (repo.name.len == 0) "(workspace)" else repo.name,
            .identity = identity,
            .group = std.Io.Dir.path.dirname(repo.name),
            .branch = repo.branch,
            .pin = pin,
        };
        readRepo(ws, arena, repo, identity, &row, if (list_issues) &issues else null, if (list_patches) &patches else null) catch {};
        // the root repo isn't one of the pullfile's
        if (repo.name.len > 0) try repos.append(aa, row);
    }
    page.repos = repos.items;
    page.issues = issues.items;
    page.patches = patches.items;

    if (route.view == .stacks) {
        var rows: std.ArrayList(ui.Workspace.StackRow) = .empty;
        for (try listStacks(ws, arena)) |stack| {
            var count: usize = 0;
            var iter = evt.Stack.memberIterator(stack.record.event.members);
            while (try iter.next()) |_| count += 1;
            try rows.append(aa, .{
                .id = try aa.dupe(u8, &stack.id),
                .title = stack.record.event.title,
                .status = @tagName(stack.record.event.status.kind()),
                .members = count,
                .conflicted_fields = stack.conflicted_fields,
                .url = try ui.Workspace.stackUrl(aa, &stack.id),
            });
        }
        page.stacks = rows.items;
    }
    if (route.view == .stack) page.stack = stackDetail(ws, arena, route.selected.slice(), pf) catch |err| switch (err) {
        error.StackNotFound => null,
        else => |e| return e,
    };
    return page;
}

// a stack with each member's patch and what merging it would do
pub fn stackDetail(ws: *const Workspace, arena: *std.heap.ArenaAllocator, id: []const u8, pf: ?pullfile.Pullfile) !ui.Workspace.StackDetail {
    const aa = arena.allocator();
    const found = try readStack(ws, arena, id);
    const stack = found.record.event;
    var members: std.ArrayList(ui.Workspace.MemberRow) = .empty;
    var mergeable = true;
    var iter = evt.Stack.memberIterator(stack.members);
    while (try iter.next()) |member| {
        var row: ui.Workspace.MemberRow = .{ .repo = member.repo, .patch_id = member.patch_id, .status = "missing", .mergeable = "missing" };
        if (pf) |p| for (p.repos) |r| if (std.mem.eql(u8, r.name, member.repo)) {
            row.pin = r.commit;
        };
        if (ws.byName(member.repo)) |repo| {
            const identity = try ws.identity(aa, repo);
            row.identity = identity;
            if (ui.RoutablePage.repoThreadRoute(.patch, identity, member.patch_id)) |route| row.url = try route.toUrl(arena);
            // a merged stack's members merged long ago, so there's nothing to check
            const state = try memberMerge(ws, arena, repo, member.patch_id, .check);
            row.status = state.status;
            row.mergeable = @tagName(state.outcome);
            row.title = state.title;
            row.source_branch = state.source_branch;
            row.target_branch = state.target_branch;
            row.target_oid = state.target_oid;
        }
        if (stack.status == .merged) row.target_oid = evt.Stack.pinOf(stack.status.merged.pins, member.repo) orelse row.target_oid;
        switch (std.meta.stringToEnum(Outcome, row.mergeable) orelse .missing) {
            .fast_forward, .clean, .nothing, .merged => {},
            else => mergeable = false,
        }
        try members.append(aa, row);
    }
    return .{
        .id = try aa.dupe(u8, &found.id),
        .title = stack.title,
        .description = stack.description,
        .labels = stack.labels,
        .status = @tagName(stack.status.kind()),
        .author_email = found.record.author_email,
        .conflicted_fields = found.conflicted_fields,
        .members = members.items,
        .mergeable = mergeable and found.conflicted_fields.len == 0,
    };
}

// a repo row's head, and its open issues and patches
fn readRepo(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, identity: []const u8, row: *ui.Workspace.RepoRow, issues: ?*std.ArrayList(ui.Workspace.IssueRow), patches: ?*std.ArrayList(ui.Workspace.PatchRow)) !void {
    try withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            const aa = args.arena.allocator();
            args.row.cloned = true;
            var head_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
            if (r.head(w.io, &head_buffer)) |head| switch (head) {
                .ref => |ref| {
                    args.row.head_branch = try aa.dupe(u8, ref.name);
                    if (try r.readRef(w.io, ref)) |oid| args.row.head = try aa.dupe(u8, &oid);
                },
                .oid => |oid| args.row.head = try aa.dupe(u8, oid),
            } else |_| {}
            if (args.row.head) |head| if (args.row.pin) |pin| {
                args.row.ahead = !std.mem.eql(u8, head, pin);
            };

            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            const DB = evt.EventDB(opts.hash);

            const issue_ids = try statusIds(DB, opts.hash, moment, args.arena, evt.Issue.status_to_id_set_key, "open");
            args.row.open_issues = issue_ids.len;
            if (args.issues) |list| for (issue_ids) |id| {
                const issue = (try evt.readRecordSubset(evt.Issue, struct { event: struct { title: []const u8, labels: []const u8 } }, DB, opts.hash, moment, args.arena, &id)) orelse continue;
                const hex = try aa.dupe(u8, &std.fmt.bytesToHex(id, .lower));
                const route = ui.RoutablePage.repoThreadRoute(.issue, args.identity, hex) orelse continue;
                try list.append(aa, .{ .repo = args.row.name, .identity = args.identity, .id = hex, .title = issue.event.title, .labels = issue.event.labels, .url = try route.toUrl(args.arena) });
            };

            const patch_ids = try statusIds(DB, opts.hash, moment, args.arena, evt.Patch.status_to_id_set_key, "open");
            args.row.open_patches = patch_ids.len;
            if (args.patches) |list| for (patch_ids) |id| {
                const patch = (try evt.readRecordSubset(evt.Patch, struct { event: struct { title: []const u8, source_branch: ?[]const u8, target_branch: []const u8 } }, DB, opts.hash, moment, args.arena, &id)) orelse continue;
                const hex = try aa.dupe(u8, &std.fmt.bytesToHex(id, .lower));
                const route = ui.RoutablePage.repoThreadRoute(.patch, args.identity, hex) orelse continue;
                try list.append(aa, .{ .repo = args.row.name, .identity = args.identity, .id = hex, .title = patch.event.title, .source_branch = patch.event.source_branch orelse "(fork)", .target_branch = patch.event.target_branch, .status = "open", .url = try route.toUrl(args.arena) });
            };
        }
    }.run, .{ .arena = arena, .row = row, .identity = identity, .issues = issues, .patches = patches });
}

// the ids in a kind's per-status set, newest first
fn statusIds(comptime DB: type, comptime hash_kind: hash.HashKind, moment: DB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, key: []const u8, status: []const u8) ![]const [evt.event_id_size]u8 {
    var out: std.ArrayList([evt.event_id_size]u8) = .empty;
    const map_cursor = try moment.getCursor(hash.hashInt(hash_kind, key)) orelse return out.items;
    const map = try DB.SortedMap(.read_only).init(map_cursor);
    const set_cursor = try map.getCursor(status) orelse return out.items;
    const set = try DB.SortedSet(.read_only).init(set_cursor);
    var iter = try set.iteratorFromIndex(0);
    while (try iter.next()) |cursor| try out.append(arena.allocator(), try evt.readOrderKeyId(DB, cursor));
    return out.items;
}

//
// `cpull stack`, which pull drives
//

pub fn runStackCommand(
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    options: cmd.StackOptions,
    global_config_path: ?[]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const root = if (options.workspace_path) |path|
        try std.Io.Dir.path.resolve(aa, &.{ cwd, path })
    else
        (try pullfile.findRoot(io, aa, cwd)) orelse {
            try err.print("no pullfile.plist in {s} or any parent\n", .{cwd});
            return error.HandledError;
        };
    const ws = try Workspace.load(io, gpa, aa, root, global_config_path);
    runStack(ws, &arena, options, out) catch |e| {
        try err.print("cpull stack {s}: {s}\n", .{ @tagName(options.action), @errorName(e) });
        return error.HandledError;
    };
}

fn runStack(ws: *Workspace, arena: *std.heap.ArenaAllocator, options: cmd.StackOptions, out: *std.Io.Writer) !void {
    const aa = arena.allocator();
    switch (options.action) {
        .new => {
            var members: std.ArrayList(NewMember) = .empty;
            for (options.args) |arg| {
                var parts = std.mem.splitScalar(u8, arg, ':');
                const repo = parts.next() orelse return error.InvalidMember;
                const source = parts.next() orelse return error.InvalidMember;
                const target = parts.next();
                if (parts.next() != null or repo.len == 0 or source.len == 0) return error.InvalidMember;
                try members.append(aa, .{ .repo = repo, .source_branch = source, .target_branch = target });
            }
            const created = try createStack(ws, aa, options.title, options.description, options.labels, members.items);
            try std.json.Stringify.value(.{ .id = &created.id, .members = created.members }, .{}, out);
        },
        .merge => {
            const found = try readStack(ws, arena, options.args[0]);
            const pins = try mergeStack(ws, arena, &found.id);
            try std.json.Stringify.value(.{ .id = &found.id, .pins = pins }, .{}, out);
        },
        .show => try std.json.Stringify.value(try stackDetail(ws, arena, options.args[0], pullfile.load(ws.io, aa, ws.root) catch null), .{}, out),
        .list => {
            const page = try buildPage(ws, arena, .{ .view = .stacks });
            try std.json.Stringify.value(page.stacks, .{}, out);
        },
    }
    try out.writeByte('\n');
    try out.flush();
}
