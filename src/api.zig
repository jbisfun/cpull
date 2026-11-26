// cpull's JSON API (theme docs/workspace-tools.md §4), served by the
// workspace server at /api for the workspace's other tools (idlci, the wiki,
// radar) and pull:
//
//   GET  /api/health
//   GET  /api/repos                         -> [Repo]
//   GET  /api/issues?repo=R&status=open|closed|all&label=L&anchored=1&file=F -> [Issue]
//   GET  /api/issues/<repo>/<id>            -> Issue + "comments": [Comment]
//   POST /api/issues                        {repo, title, description, labels?, anchor?} -> 201 Issue
//   POST /api/issues/<repo>/<id>/comment    {body, status?}  -> Issue
//   POST /api/issues/<repo>/<id>/close      {comment?}       -> Issue
//   POST /api/issues/<repo>/<id>/reopen     {comment?}       -> Issue
//   GET  /api/reports?status=&repo=&file=   -> [Report]
//   GET  /api/reports/<id>                  -> Report + "excerpt": Excerpt|null
//   GET  /api/patches?repo=R                -> [Patch]
//   GET  /api/patches/<repo>/<id>           -> Patch
//   GET  /api/stacks/<id>                   -> Stack
//   GET  /api/records?repo=R[&repo=R2...]   -> `cpull records PATH...`'s json
//
// `repo` is a pullfile repo name ("group/name" for nested ones) or "." for
// the events repo; ids accept a unique prefix of 6+ hex digits. Writes are
// made as pull's identity (the repo's pinned user.name/email) and refuse a
// request whose Origin names another site. Errors are {"error": "..."}.
const std = @import("std");
const evt = @import("event.zig");
const ws_mod = @import("workspace.zig");
const forge = @import("forge.zig");
const records = @import("records.zig");
const report = @import("report/report.zig");
const anchor_mod = @import("report/anchor.zig");
const tools_web = @import("tools/web.zig");
const rp = @import("xit").repo;

const Workspace = ws_mod.Workspace;
const Repo = ws_mod.Repo;
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;

pub const prefix = "/api";
pub const version = "0.2.0";

const HttpError = struct { status: std.http.Status, message: []const u8 };

// web.Mount.handle for /api
pub fn handle(ctx: *anyopaque, io: std.Io, request: *Request, gpa: Allocator, target: []const u8) anyerror!void {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    _ = io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |at| target[at + 1 ..] else "";
    const method = request.head.method;
    var fail: HttpError = .{ .status = .not_found, .message = "no such api route" };
    if (method == .POST) {
        if (!tools_web.sameOrigin(request)) return respondError(request, a, .forbidden, "cross-origin writes are refused");
        var buf: [1024]u8 = undefined;
        const body = request.readerExpectNone(&buf).allocRemaining(a, .limited(4 << 20)) catch return respondError(request, a, .bad_request, "unreadable body");
        const value = post(ws, &arena, path, body, &fail) catch |e| return respondFail(request, a, fail, e);
        return respondJson(request, a, value.status, value.json);
    }
    if (method != .GET and method != .HEAD) return respondError(request, a, .method_not_allowed, "GET or POST");
    const json = get(ws, &arena, path, query, &fail) catch |e| return respondFail(request, a, fail, e);
    return respondJson(request, a, .ok, json);
}

const Posted = struct { status: std.http.Status, json: []const u8 };

fn get(ws: *Workspace, arena: *std.heap.ArenaAllocator, path: []const u8, query: []const u8, fail: *HttpError) ![]const u8 {
    const a = arena.allocator();
    if (eql(path, "/api/health")) return stringify(a, .{ .ok = true, .tool = "cpull", .root = ws.root, .version = version });
    if (eql(path, "/api/repos")) return stringify(a, try listRepos(ws, arena));
    if (eql(path, "/api/issues")) {
        const want_status = try param(a, query, "status") orelse "open";
        const label = try param(a, query, "label");
        const anchored = if (try param(a, query, "anchored")) |v| eql(v, "1") or eql(v, "true") else false;
        const file = try param(a, query, "file");
        const repos: []const Repo = if (try param(a, query, "repo")) |name| &.{try repoNamed(ws, name, fail)} else try forge.allRepos(ws, a);
        var out: std.ArrayList(Issue) = .empty;
        for (repos) |repo| for (try forge.issues(ws, arena, repo)) |i| {
            if (!statusMatches(want_status, @tagName(i.status))) continue;
            if (label) |l| if (!hasLabel(i.labels, l)) continue;
            if (anchored and i.anchor == null) continue;
            if (file) |f| if (i.anchor == null or !eql(i.anchor.?.file, f)) continue;
            try out.append(a, try issueJson(ws, arena, repo, i));
        };
        return stringify(a, out.items);
    }
    if (std.mem.startsWith(u8, path, "/api/issues/")) {
        const repo_name, const id = splitLast(path["/api/issues/".len..]) orelse return notFound(fail);
        const repo = try repoNamed(ws, repo_name, fail);
        const issue = try findIssue(ws, arena, repo, id, fail);
        return issueWithComments(ws, arena, repo, issue);
    }
    if (eql(path, "/api/reports")) {
        const want_status = try param(a, query, "status") orelse "open";
        const repo_name = try param(a, query, "repo");
        const file = try param(a, query, "file");
        const repo_display: ?[]const u8 = if (repo_name) |n| report.displayName(try repoNamed(ws, n, fail)) else null;
        var out: std.ArrayList(report.Report) = .empty;
        for (try report.list(ws, arena, !eql(want_status, "open"))) |r| {
            if (!statusMatches(want_status, r.status)) continue;
            if (repo_display) |n| if (!eql(n, r.repo)) continue;
            if (file) |f| if (!eql(f, r.file)) continue;
            try out.append(a, r);
        }
        return stringify(a, out.items);
    }
    if (std.mem.startsWith(u8, path, "/api/reports/")) {
        const id = path["/api/reports/".len..];
        if (id.len < 6) return badRequest(fail, "ids need at least 6 hex digits");
        const found = report.find(ws, arena, id) catch |e| switch (e) {
            error.ReportNotFound => return notFound(fail),
            error.AmbiguousId => return badRequest(fail, "that id prefix matches more than one report"),
            else => return e,
        };
        const repo = try report.resolveRepo(ws, found.repo);
        const ex = excerptOf(ws, arena, repo, found) catch null;
        return objectWith(a, found, "excerpt", if (ex) |x| ExcerptJson.of(x) else null);
    }
    if (eql(path, "/api/patches")) {
        const repos: []const Repo = if (try param(a, query, "repo")) |name| &.{try repoNamed(ws, name, fail)} else ws.repos;
        var out: std.ArrayList(Patch) = .empty;
        for (repos) |repo| for (try forge.patches(ws, arena, repo)) |p| try out.append(a, try patchJson(ws, arena, repo, p));
        return stringify(a, out.items);
    }
    if (std.mem.startsWith(u8, path, "/api/patches/")) {
        const repo_name, const id = splitLast(path["/api/patches/".len..]) orelse return notFound(fail);
        const repo = try repoNamed(ws, repo_name, fail);
        if (id.len < 6) return badRequest(fail, "ids need at least 6 hex digits");
        const p = forge.findPatch(ws, arena, repo, id) catch |e| switch (e) {
            error.PatchNotFound => return notFound(fail),
            error.AmbiguousId => return badRequest(fail, "that id prefix matches more than one patch"),
            else => return e,
        };
        return stringify(a, try patchJson(ws, arena, repo, p));
    }
    if (std.mem.startsWith(u8, path, "/api/stacks/")) {
        const id = path["/api/stacks/".len..];
        if (id.len < 6) return badRequest(fail, "ids need at least 6 hex digits");
        const found = ws_mod.readStack(ws, arena, id) catch |e| {
            fail.* = .{ .status = .not_found, .message = try std.fmt.allocPrint(a, "stack {s}: {s}", .{ id, @errorName(e) }) };
            return error.Http;
        };
        return stringify(a, try stackJson(ws, arena, found));
    }
    if (eql(path, "/api/records")) {
        var paths: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (!eql(kv[0..eq], "repo")) continue;
            const name = try decode(a, kv[eq + 1 ..]);
            try paths.append(a, (try repoNamed(ws, name, fail)).path);
        }
        if (paths.items.len == 0) return badRequest(fail, "name at least one repo (?repo=R)");
        var out: std.Io.Writer.Allocating = .init(a);
        try records.run(ws.io, ws.gpa, ws.root, .{ .paths = paths.items }, ws.global_config_path, &out.writer);
        return std.mem.trimEnd(u8, out.written(), "\n");
    }
    return notFound(fail);
}

fn post(ws: *Workspace, arena: *std.heap.ArenaAllocator, path: []const u8, body: []const u8, fail: *HttpError) !Posted {
    const a = arena.allocator();
    if (eql(path, "/api/issues")) {
        const New = struct {
            repo: []const u8 = ".",
            title: []const u8,
            description: []const u8 = "",
            labels: []const u8 = "",
            anchor: ?evt.Issue.Anchor = null,
            // optional, beyond the contract: a migration re-filing a record
            // with its own id, filing time and status (radar migrate)
            id: ?[]const u8 = null,
            created: ?u64 = null,
            status: ?evt.Issue.Status = null,
        };
        const new = std.json.parseFromSliceLeaky(New, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return badRequest(fail, "expected {repo, title, description, labels?, anchor?}");
        const repo = try repoNamed(ws, new.repo, fail);
        var labels = new.labels;
        // an anchored issue is a report
        if (new.anchor != null) labels = try report.joinLabels(a, labels, &.{report.label});
        var given: ?[forge.id_len]u8 = null;
        if (new.id) |id| {
            if (id.len != forge.id_len) return badRequest(fail, "id must be 32 hex digits");
            _ = evt.parseEventId(id) catch return badRequest(fail, "id must be 32 lowercase hex digits");
            given = id[0..forge.id_len].*;
        }
        const id = forge.fileIssueWith(ws, repo, .{
            .title = std.mem.trim(u8, new.title, " \t\r\n"),
            .description = new.description,
            .labels = labels,
            .anchor = new.anchor,
            .status = new.status orelse .open,
            .id = given,
            .timestamp = new.created,
        }) catch |e| switch (e) {
            error.InvalidTitle => return badRequest(fail, "the title is empty or too long"),
            error.IssueExists => {
                fail.* = .{ .status = .conflict, .message = "an issue with that id exists" };
                return error.Http;
            },
            else => return e,
        };
        const issue = (try forge.readIssue(ws, arena, repo, &id)) orelse return error.IssueNotFiled;
        return .{ .status = .created, .json = try stringify(a, try issueJson(ws, arena, repo, issue)) };
    }
    if (std.mem.startsWith(u8, path, "/api/issues/")) {
        const rest, const action = splitLast(path["/api/issues/".len..]) orelse return notFound(fail);
        const repo_name, const id = splitLast(rest) orelse return notFound(fail);
        const repo = try repoNamed(ws, repo_name, fail);
        const issue = try findIssue(ws, arena, repo, id, fail);
        const Args = struct { body: ?[]const u8 = null, comment: ?[]const u8 = null, status: ?evt.Issue.Status = null };
        const args = if (std.mem.trim(u8, body, " \r\n").len == 0) Args{} else std.json.parseFromSliceLeaky(Args, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return badRequest(fail, "expected a json object");
        const new_status: ?evt.Issue.Status, const text: ?[]const u8 = if (eql(action, "comment"))
            .{ args.status, args.body orelse return badRequest(fail, "body is required") }
        else if (eql(action, "close"))
            .{ .closed, args.comment }
        else if (eql(action, "reopen"))
            .{ .open, args.comment }
        else
            return notFound(fail);
        const changes = if (new_status) |s| s != issue.status else false;
        const comment: ?[]const u8 = if (text) |t| (if (std.mem.trim(u8, t, " \t\r\n").len > 0) t else null) else null;
        if (comment == null and eql(action, "comment")) return badRequest(fail, "body is required");
        if (comment) |t|
            try forge.commentIssue(ws, repo, issue.id, t, if (changes) new_status else null)
        else if (changes)
            try forge.setIssueStatus(ws, repo, issue.id, new_status.?);
        const now = (try forge.readIssue(ws, arena, repo, issue.id)) orelse issue;
        return .{ .status = .ok, .json = try stringify(a, try issueJson(ws, arena, repo, now)) };
    }
    return notFound(fail);
}

//
// the shapes
//

const Issue = struct {
    id: []const u8,
    repo: []const u8,
    title: []const u8,
    description: []const u8,
    labels: []const u8,
    status: []const u8,
    author: ?[]const u8,
    created: []const u8,
    url: []const u8,
    anchor: ?evt.Issue.Anchor,

    // `anchor` only when set
    pub fn jsonStringify(self: Issue, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Issue).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "anchor")) {
                try jw.objectField(name);
                try jw.write(@field(self, name));
            }
        }
        if (self.anchor) |x| {
            try jw.objectField("anchor");
            try jw.write(x);
        }
        try jw.endObject();
    }
};

const Comment = struct { id: []const u8, parent_id: []const u8, body: []const u8, author: ?[]const u8, created: []const u8 };

const RepoJson = struct {
    name: []const u8,
    identity: []const u8,
    path: []const u8,
    branch: []const u8,
    url: []const u8,
    issues_url: []const u8,
    cloned: bool,
    open_issues: usize,
    open_reports: usize,
};

const Patch = struct {
    id: []const u8,
    repo: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    source_branch: ?[]const u8,
    tip: ?[]const u8,
    url: []const u8,
};

const StackMember = struct { repo: []const u8, patch_id: []const u8, branch: []const u8, oid: []const u8 };
const Stack = struct { id: []const u8, title: []const u8, description: []const u8, status: []const u8, url: []const u8, members: []const StackMember };

const ExcerptJson = struct {
    file: []const u8,
    line: u64,
    filed_line: u64,
    first: u64,
    lines: []const []const u8,
    commit: []const u8,
    at_filed_commit: bool,
    changed: bool,

    fn of(x: anchor_mod.Excerpt) ExcerptJson {
        return .{ .file = x.file, .line = x.line, .filed_line = x.filed_line, .first = x.first, .lines = x.lines, .commit = x.commit, .at_filed_commit = x.at_filed_commit, .changed = x.changed };
    }
};

fn issueJson(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, i: forge.IssueInfo) !Issue {
    const a = arena.allocator();
    return .{
        .id = i.id,
        .repo = forge.displayName(repo),
        .title = i.title,
        .description = i.description,
        .labels = i.labels,
        .status = @tagName(i.status),
        .author = i.author,
        .created = try report.formatTime(a, i.created_timestamp),
        .url = try forge.issueUrl(ws, arena, repo, i.id),
        .anchor = i.anchor,
    };
}

fn issueWithComments(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, i: forge.IssueInfo) ![]const u8 {
    const a = arena.allocator();
    var list: std.ArrayList(Comment) = .empty;
    for (try forge.comments(ws, arena, repo, i.id)) |c| try list.append(a, .{
        .id = c.id,
        .parent_id = c.parent_id,
        .body = c.body,
        .author = c.author,
        .created = try report.formatTime(a, c.created_timestamp),
    });
    return objectWith(a, try issueJson(ws, arena, repo, i), "comments", list.items);
}

fn patchJson(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, p: forge.PatchInfo) !Patch {
    const a = arena.allocator();
    return .{
        .id = p.id,
        .repo = forge.displayName(repo),
        .title = p.title,
        .description = p.description,
        .status = p.status,
        .source_branch = p.source_branch,
        .tip = if (p.source_branch) |b| forge.branchTip(ws.io, a, repo.path, b) else null,
        .url = try forge.patchUrl(ws, arena, repo, p.id),
    };
}

fn stackJson(ws: *const Workspace, arena: *std.heap.ArenaAllocator, found: evt.Stack.WithId) !Stack {
    const a = arena.allocator();
    const tools_runs = @import("tools/runs.zig");
    var members: std.ArrayList(StackMember) = .empty;
    for (try tools_runs.stackMembers(ws, arena, &found.id)) |m| try members.append(a, .{ .repo = m.repo, .patch_id = m.patch_id, .branch = m.branch, .oid = m.oid });
    const ev = found.record.event;
    return .{
        .id = try a.dupe(u8, &found.id),
        .title = ev.title,
        .description = ev.description,
        .status = @tagName(ev.status.kind()),
        .url = try @import("ui.zig").Workspace.stackUrl(a, &found.id),
        .members = members.items,
    };
}

fn listRepos(ws: *const Workspace, arena: *std.heap.ArenaAllocator) ![]const RepoJson {
    const a = arena.allocator();
    var out: std.ArrayList(RepoJson) = .empty;
    for (try forge.allRepos(ws, a)) |repo| {
        const identity = try ws.identity(a, repo);
        const git = try std.fs.path.join(a, &.{ repo.path, ".git" });
        const cloned = if (std.Io.Dir.cwd().statFile(ws.io, git, .{})) |_| true else |_| false;
        var open_issues: usize = 0;
        var open_reports: usize = 0;
        if (cloned) for (try forge.issues(ws, arena, repo)) |i| if (i.status == .open) {
            open_issues += 1;
            if (i.anchor != null) open_reports += 1;
        };
        try out.append(a, .{
            .name = forge.displayName(repo),
            .identity = identity,
            .path = repo.path,
            .branch = repo.branch,
            .url = try a.print("/{s}", .{identity}),
            .issues_url = try a.print("/{s}/issues", .{identity}),
            .cloned = cloned,
            .open_issues = open_issues,
            .open_reports = open_reports,
        });
    }
    return out.items;
}

fn excerptOf(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, r: report.Report) !?anchor_mod.Excerpt {
    var out: ?anchor_mod.Excerpt = null;
    try ws_mod.withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, repo_: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            args.out.* = try anchor_mod.excerpt(.git, opts, repo_, w.io, args.arena, .{ .file = args.r.file, .line = args.r.line, .line_text = args.r.line_text, .quote = args.r.quote, .commit = args.r.commit });
        }
    }.run, .{ .arena = arena, .r = r, .out = &out });
    return out;
}

//
// helpers
//

fn repoNamed(ws: *const Workspace, name: []const u8, fail: *HttpError) !Repo {
    return report.resolveRepo(ws, name) catch |e| {
        fail.* = .{ .status = .not_found, .message = switch (e) {
            error.NoEventsRepo => "the workspace has no events repo",
            else => "no such repo in the pullfile (\".\" is the workspace's events repo)",
        } };
        return error.Http;
    };
}

fn findIssue(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, id: []const u8, fail: *HttpError) !forge.IssueInfo {
    return forge.findIssue(ws, arena, repo, id) catch |e| {
        fail.* = switch (e) {
            error.IdTooShort => .{ .status = .bad_request, .message = "ids need at least 6 hex digits" },
            error.AmbiguousId => .{ .status = .bad_request, .message = "that id prefix matches more than one issue" },
            error.IssueNotFound => .{ .status = .not_found, .message = "no such issue" },
            else => return e,
        };
        return error.Http;
    };
}

// "<repo>/<last>" -> {repo, last}; a bare "<last>" names the events repo
fn splitLast(s: []const u8) ?struct { []const u8, []const u8 } {
    const t = std.mem.trimEnd(u8, s, "/");
    const slash = std.mem.lastIndexOfScalar(u8, t, '/') orelse return if (t.len > 0) .{ ".", t } else null;
    if (slash + 1 >= t.len) return null;
    return .{ t[0..slash], t[slash + 1 ..] };
}

fn statusMatches(want: []const u8, have: []const u8) bool {
    return eql(want, "all") or eql(want, have);
}

fn hasLabel(labels: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, labels, ' ');
    while (it.next()) |l| if (eql(l, want)) return true;
    return false;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn notFound(fail: *HttpError) error{Http} {
    fail.* = .{ .status = .not_found, .message = "not found" };
    return error.Http;
}

fn badRequest(fail: *HttpError, message: []const u8) error{Http} {
    fail.* = .{ .status = .bad_request, .message = message };
    return error.Http;
}

fn stringify(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

// `value`'s json object with one more field
fn objectWith(a: Allocator, value: anytype, comptime name: []const u8, extra: anytype) ![]const u8 {
    const base = try stringify(a, value);
    std.debug.assert(base.len >= 2 and base[base.len - 1] == '}');
    const more = try stringify(a, extra);
    const sep = if (base.len == 2) "" else ",";
    return std.fmt.allocPrint(a, "{s}{s}\"" ++ name ++ "\":{s}}}", .{ base[0 .. base.len - 1], sep, more });
}

fn decode(a: Allocator, raw: []const u8) ![]const u8 {
    const v = try a.dupe(u8, raw);
    std.mem.replaceScalar(u8, v, '+', ' ');
    return std.Uri.percentDecodeInPlace(v);
}

fn param(a: Allocator, query: []const u8, key: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (eql(kv[0..eq], key)) return try decode(a, kv[eq + 1 ..]);
    }
    return null;
}

fn respondJson(request: *Request, a: Allocator, status: std.http.Status, body: []const u8) !void {
    _ = a;
    try request.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn respondError(request: *Request, a: Allocator, status: std.http.Status, message: []const u8) !void {
    try respondJson(request, a, status, try stringify(a, .{ .@"error" = message }));
}

fn respondFail(request: *Request, a: Allocator, fail: HttpError, err: anyerror) !void {
    if (err == error.Http) return respondError(request, a, fail.status, fail.message);
    const message = switch (err) {
        error.NoPullIdentity => "the repo has no user.name/user.email; serve the workspace with `pull cpull open`",
        error.LabelTooLong => "a label is too long",
        else => @errorName(err),
    };
    const status: std.http.Status = switch (err) {
        error.NoPullIdentity => .forbidden,
        error.LabelTooLong, error.InvalidEventId => .bad_request,
        else => .internal_server_error,
    };
    return respondError(request, a, status, message);
}

test splitLast {
    try std.testing.expectEqualStrings("fossify-ios/calc", splitLast("fossify-ios/calc/abcdef").?[0]);
    try std.testing.expectEqualStrings("abcdef", splitLast("fossify-ios/calc/abcdef").?[1]);
    try std.testing.expectEqualStrings(".", splitLast("abcdef").?[0]);
    try std.testing.expect(splitLast("") == null);
}

test objectWith {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("{\"a\":1,\"x\":null}", try objectWith(arena.allocator(), .{ .a = 1 }, "x", @as(?u8, null)));
}
