// the forge reads and writes the CI integration needs, over one workspace
// repo's cpull events: patch and issue lookups by id or prefix, an index of a
// repo's issues for linking `#id` mentions, and filing, commenting on,
// closing and reopening issues as pull's identity (the repo's local
// user.name/user.email, which `pull cpull open` pins; without it writes fail
// with error.NoPullIdentity, like every workspace write).
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const ws_mod = @import("../workspace.zig");
const Workspace = ws_mod.Workspace;
const Repo = ws_mod.Repo;

pub const id_len = evt.event_id_size * 2;

pub const PatchInfo = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    source_branch: ?[]const u8,
    target_branch: []const u8,
    status: []const u8,
};

pub const IssueInfo = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    labels: []const u8,
    status: evt.Issue.Status,
};

// every repo issues can live in: the root events repo, then the pullfile's
pub fn allRepos(ws: *const Workspace, aa: std.mem.Allocator) ![]const Repo {
    if (ws.events) |e| if (e.name.len == 0) return std.mem.concat(aa, Repo, &.{ &.{e}, ws.repos });
    return ws.repos;
}

// the repo a "<workspace>:<key>" identity names
pub fn repoOfIdentity(ws: *const Workspace, identity: []const u8) ?Repo {
    return ws.byIdentity(identity);
}

// a repo's name for display and the CI's `repo` column ("." for the root events repo)
pub fn displayName(repo: Repo) []const u8 {
    return if (repo.name.len == 0) "." else repo.name;
}

pub fn byDisplayName(ws: *const Workspace, name: []const u8) ?Repo {
    if (std.mem.eql(u8, name, ".")) return ws.events;
    return ws.byName(name);
}

fn statusIds(comptime DB: type, comptime hash_kind: hash.HashKind, moment: DB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, key: []const u8, status: []const u8, out: *std.ArrayList([evt.event_id_size]u8)) !void {
    const map_cursor = try moment.getCursor(hash.hashInt(hash_kind, key)) orelse return;
    const map = try DB.SortedMap(.read_only).init(map_cursor);
    const set_cursor = try map.getCursor(status) orelse return;
    const set = try DB.SortedSet(.read_only).init(set_cursor);
    var iter = try set.iteratorFromIndex(0);
    while (try iter.next()) |cursor| try out.append(arena.allocator(), try evt.readOrderKeyId(DB, cursor));
}

// every patch of a repo (newest first per status)
pub fn patches(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo) ![]PatchInfo {
    var out: std.ArrayList(PatchInfo) = .empty;
    ws_mod.withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            const aa = args.arena.allocator();
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            const DB = evt.EventDB(opts.hash);
            var ids: std.ArrayList([evt.event_id_size]u8) = .empty;
            for ([_][]const u8{ "open", "closed", "merged" }) |status| try statusIds(DB, opts.hash, moment, args.arena, evt.Patch.status_to_id_set_key, status, &ids);
            for (ids.items) |id| {
                const rec = (try evt.readRecordSubset(evt.Patch, struct { removed: bool, event: struct { title: []const u8, description: []const u8, source_branch: ?[]const u8, target_branch: []const u8, status: evt.Patch.Status } }, DB, opts.hash, moment, args.arena, &id)) orelse continue;
                if (rec.removed) continue;
                try args.out.append(aa, .{
                    .id = try aa.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
                    .title = rec.event.title,
                    .description = rec.event.description,
                    .source_branch = rec.event.source_branch,
                    .target_branch = rec.event.target_branch,
                    .status = @tagName(rec.event.status.kind()),
                });
            }
        }
    }.run, .{ .arena = arena, .out = &out }) catch |e| switch (e) {
        error.RepoNotFound, error.FileNotFound, error.NotDir => return out.items,
        else => return e,
    };
    return out.items;
}

// the patch whose id is or starts with `prefix`
pub fn findPatch(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, prefix: []const u8) !PatchInfo {
    const want = std.mem.trimStart(u8, prefix, "#");
    if (want.len == 0) return error.PatchNotFound;
    var found: ?PatchInfo = null;
    for (try patches(ws, arena, repo)) |p| {
        if (!std.mem.startsWith(u8, p.id, want)) continue;
        if (found != null) return error.AmbiguousId;
        found = p;
    }
    return found orelse error.PatchNotFound;
}

// every issue of a repo, open ones first
pub fn issues(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo) ![]IssueInfo {
    var out: std.ArrayList(IssueInfo) = .empty;
    ws_mod.withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            const aa = args.arena.allocator();
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            const DB = evt.EventDB(opts.hash);
            var ids: std.ArrayList([evt.event_id_size]u8) = .empty;
            for ([_][]const u8{ "open", "closed" }) |status| try statusIds(DB, opts.hash, moment, args.arena, evt.Issue.status_to_id_set_key, status, &ids);
            for (ids.items) |id| {
                const rec = (try evt.readRecordSubset(evt.Issue, struct { removed: bool, event: struct { title: []const u8, description: []const u8, labels: []const u8, status: evt.Issue.Status } }, DB, opts.hash, moment, args.arena, &id)) orelse continue;
                if (rec.removed) continue;
                try args.out.append(aa, .{
                    .id = try aa.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
                    .title = rec.event.title,
                    .description = rec.event.description,
                    .labels = rec.event.labels,
                    .status = rec.event.status,
                });
            }
        }
    }.run, .{ .arena = arena, .out = &out }) catch |e| switch (e) {
        error.RepoNotFound, error.FileNotFound, error.NotDir => return out.items,
        else => return e,
    };
    return out.items;
}

// the one issue of `list` whose id starts with `prefix`, or null when none or several do
pub fn matchIssue(list: []const IssueInfo, prefix: []const u8) ?IssueInfo {
    var found: ?IssueInfo = null;
    for (list) |issue| {
        if (!std.mem.startsWith(u8, issue.id, prefix)) continue;
        if (found != null) return null;
        found = issue;
    }
    return found;
}

pub fn issueUrl(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, id: []const u8) ![]const u8 {
    const identity = try ws.identity(arena.allocator(), repo);
    const route = ui.RoutablePage.repoThreadRoute(.issue, identity, id) orelse return "";
    return route.toUrl(arena);
}

pub fn patchUrl(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, id: []const u8) ![]const u8 {
    const identity = try ws.identity(arena.allocator(), repo);
    const route = ui.RoutablePage.repoThreadRoute(.patch, identity, id) orelse return "";
    return route.toUrl(arena);
}

// file an issue; returns its id
pub fn fileIssue(ws: *const Workspace, repo: Repo, title: []const u8, description: []const u8, labels: []const u8) ![id_len]u8 {
    var id_bytes: [evt.event_id_size]u8 = undefined;
    ws.io.random(&id_bytes);
    const id = std.fmt.bytesToHex(id_bytes, .lower);
    try ws_mod.withRepo(ws, repo, true, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{.{
                .id = args.id,
                .timestamp = @intCast(std.Io.Timestamp.now(w.io, .real).toSeconds()),
                .author = author,
                .event = .{ .issue = .{ .title = args.title, .description = args.description, .labels = args.labels } },
            }});
        }
    }.run, .{ .id = id, .title = title, .description = description, .labels = labels });
    return id;
}

// the issue `id` (a full id), or null
pub fn readIssue(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, id: []const u8) !?IssueInfo {
    const id_bytes = evt.parseEventId(id) catch return null;
    var out: ?IssueInfo = null;
    try ws_mod.withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            const rec = (try evt.readRecordSubset(evt.Issue, struct { removed: bool, event: struct { title: []const u8, description: []const u8, labels: []const u8, status: evt.Issue.Status } }, evt.EventDB(opts.hash), opts.hash, moment, args.arena, args.id)) orelse return;
            if (rec.removed) return;
            args.out.* = .{ .id = args.hex, .title = rec.event.title, .description = rec.event.description, .labels = rec.event.labels, .status = rec.event.status };
        }
    }.run, .{ .arena = arena, .id = &id_bytes, .hex = id, .out = &out });
    return out;
}

// comment on an issue and optionally change its status, in one go
pub fn commentIssue(ws: *const Workspace, repo: Repo, id: []const u8, body: []const u8, status: ?evt.Issue.Status) !void {
    if (id.len != id_len) return error.InvalidEventId;
    const id_bytes = try evt.parseEventId(id);
    try ws_mod.withRepo(ws, repo, true, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            const hex: *const [id_len]u8 = args.hex[0..id_len];
            _ = try evt.Comment.create(.local, .git, opts, w.io, w.gpa, r, .issue, hex, hex, args.body, author);
            if (args.status) |s| try evt.Issue.update(.local, .git, opts, w.io, w.gpa, r, args.id, .{ .status = s }, author);
        }
    }.run, .{ .id = &id_bytes, .hex = id, .body = body, .status = status });
}

// the tip of `branch` in a repo (git CLI: workspace repos may be linked worktrees)
pub fn branchTip(io: std.Io, aa: std.mem.Allocator, repo_path: []const u8, branch: []const u8) ?[]const u8 {
    const ref = aa.print("refs/heads/{s}", .{branch}) catch return null;
    return gitLine(io, aa, &.{ "git", "-C", repo_path, "rev-parse", "--verify", "-q", ref });
}

pub fn headOid(io: std.Io, aa: std.mem.Allocator, repo_path: []const u8) ?[]const u8 {
    return gitLine(io, aa, &.{ "git", "-C", repo_path, "rev-parse", "--verify", "-q", "HEAD" });
}

// the branch a repo's HEAD is on, or null when detached
pub fn headBranch(io: std.Io, aa: std.mem.Allocator, repo_path: []const u8) ?[]const u8 {
    return gitLine(io, aa, &.{ "git", "-C", repo_path, "symbolic-ref", "-q", "--short", "HEAD" });
}

pub fn gitOut(io: std.Io, aa: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const r = std.process.run(aa, io, .{ .argv = argv, .stdout_limit = .limited(64 << 20), .stderr_limit = .limited(1 << 20) }) catch return null;
    if (!r.term.success()) return null;
    return r.stdout;
}

fn gitLine(io: std.Io, aa: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const out = gitOut(io, aa, argv) orelse return null;
    const line = std.mem.trim(u8, out, " \r\n");
    return if (line.len == 0) null else line;
}
