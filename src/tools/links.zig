// commit <-> issue links. A `#<issue id prefix>` (6 to 32 hex digits) in a
// commit message or a patch description names an issue: the pages link it
// (to the repo's own issue, else the workspace events repo's), and an issue's
// page lists the commits, patches, stacks and CI jobs that reference it.
// `fixes #id`, `closes #id` or `resolves #id` (and their other tenses) close
// the issue once the commit lands on the repo's pullfile branch: the
// workspace server polls each repo's branch tip and reads the commits that
// arrived since the tip it saw last (kept in integrate.json's link_tips; the first
// look only records the tip), so each commit is handled once, however often
// it runs, and a closed issue someone reopens stays open. The pullfile's
// `cpull.close_issues = false` turns closing off.
const std = @import("std");
const ui = @import("../ui.zig");
const ws_mod = @import("../workspace.zig");
const forge = @import("../forge.zig");
const status = @import("status.zig");
const tools = @import("tools.zig");
const idlci = @import("idlci.zig");
const state_mod = @import("state.zig");

const Workspace = ws_mod.Workspace;
const Repo = ws_mod.Repo;
const log = std.log.scoped(.integrate);

pub const min_len = 6;

pub const Ref = struct {
    // the hex digits after '#'
    token: []const u8,
    // preceded by fixes/closes/resolves
    closes: bool,
    // the "#..." span in the text
    start: usize,
    end: usize,
};

const keywords = [_][]const u8{ "fix", "fixes", "fixed", "close", "closes", "closed", "resolve", "resolves", "resolved" };

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// every `#hex` mention in `text`
pub fn scan(a: std.mem.Allocator, text: []const u8) ![]Ref {
    var out: std.ArrayList(Ref) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '#') continue;
        // not inside a word, url or html entity
        if (i > 0 and (isWord(text[i - 1]) or text[i - 1] == '&' or text[i - 1] == '/' or text[i - 1] == '#')) continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isHex(text[j]) and !std.ascii.isUpper(text[j])) j += 1;
        const len = j - i - 1;
        if (len < min_len or len > forge.id_len) continue;
        if (j < text.len and isWord(text[j])) continue;
        try out.append(a, .{ .token = text[i + 1 .. j], .closes = closingBefore(text[0..i]), .start = i, .end = j });
        i = j - 1;
    }
    return out.items;
}

// whether `before` ends with a closing keyword (and maybe a colon) plus spaces
fn closingBefore(before: []const u8) bool {
    var end = before.len;
    while (end > 0 and (before[end - 1] == ' ' or before[end - 1] == '\t')) end -= 1;
    if (end == before.len) return false;
    if (end > 0 and before[end - 1] == ':') end -= 1;
    var from = end;
    while (from > 0 and std.ascii.isAlphabetic(before[from - 1])) from -= 1;
    if (from == end) return false;
    if (from > 0 and isWord(before[from - 1])) return false;
    const word = before[from..end];
    for (keywords) |k| if (std.ascii.eqlIgnoreCase(k, word)) return true;
    return false;
}

// whether `text` mentions issue `id`
pub fn mentions(a: std.mem.Allocator, text: []const u8, id: []const u8) !?Ref {
    for (try scan(a, text)) |r| if (std.mem.startsWith(u8, id, r.token)) return r;
    return null;
}

//
// linking at render time
//

pub const Resolver = struct {
    ws: *const Workspace,
    arena: *std.heap.ArenaAllocator,
    repo: Repo,
    own: ?[]const forge.IssueInfo = null,
    events: ?[]const forge.IssueInfo = null,
    // also look in every other repo (a stack's description, in the events repo)
    everywhere: bool = false,

    pub const Hit = struct { issue: forge.IssueInfo, repo: Repo, url: []const u8 };

    pub fn resolve(r: *Resolver, token: []const u8) !?Hit {
        if (r.own == null) r.own = try forge.issues(r.ws, r.arena, r.repo);
        if (forge.matchIssue(r.own.?, token)) |issue| return .{ .issue = issue, .repo = r.repo, .url = try forge.issueUrl(r.ws, r.arena, r.repo, issue.id) };
        if (r.everywhere) return r.resolveEverywhere(token);
        const events = r.ws.events orelse return null;
        if (std.mem.eql(u8, events.path, r.repo.path)) return null;
        if (r.events == null) r.events = try forge.issues(r.ws, r.arena, events);
        if (forge.matchIssue(r.events.?, token)) |issue| return .{ .issue = issue, .repo = events, .url = try forge.issueUrl(r.ws, r.arena, events, issue.id) };
        return null;
    }

    fn resolveEverywhere(r: *Resolver, token: []const u8) !?Hit {
        for (r.ws.repos) |repo| {
            if (std.mem.eql(u8, repo.path, r.repo.path)) continue;
            if (forge.matchIssue(try forge.issues(r.ws, r.arena, repo), token)) |issue| return .{ .issue = issue, .repo = repo, .url = try forge.issueUrl(r.ws, r.arena, repo, issue.id) };
        }
        return null;
    }
};

fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

pub const Mode = enum { html, markdown };

// `text` with its issue mentions linked: escaped html, or markdown links
pub fn link(r: *Resolver, text: []const u8, mode: Mode) ![]const u8 {
    const a = r.arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var at: usize = 0;
    for (try scan(a, text)) |ref| {
        const hit = try r.resolve(ref.token) orelse continue;
        const before = text[at..ref.start];
        switch (mode) {
            .html => {
                try escape(&out.writer, before);
                try out.writer.writeAll("<a href=\"");
                try escape(&out.writer, hit.url);
                try out.writer.writeAll("\" title=\"");
                try escape(&out.writer, hit.issue.title);
                try out.writer.print("\">#{s}</a>", .{ref.token});
            },
            .markdown => try out.writer.print("{s}[#{s}]({s})", .{ before, ref.token, hit.url }),
        }
        at = ref.end;
    }
    if (at == 0) {
        if (mode == .markdown) return text;
        try escape(&out.writer, text);
        return out.written();
    }
    if (mode == .html) try escape(&out.writer, text[at..]) else try out.writer.writeAll(text[at..]);
    return out.written();
}

//
// closing issues when commits land
//

pub fn start(ws: *Workspace, interval_s: u64) void {
    const t = std.Thread.spawn(.{}, run, .{ ws, interval_s }) catch |e| {
        log.err("can't start the commit-link scanner: {t}", .{e});
        return;
    };
    t.detach();
}

fn run(ws: *Workspace, interval_s: u64) void {
    while (!tools.stopped()) {
        _ = scanOnce(ws) catch |e| log.warn("commit links: {t}", .{e});
        ws.io.sleep(.fromSeconds(@intCast(interval_s)), .awake) catch {};
    }
}

pub const Closed = struct { repo: []const u8, issue: []const u8, commit: []const u8 };

// one pass over every repo's pullfile branch; returns how many issues it closed
pub fn scanOnce(ws: *const Workspace) !usize {
    var arena = std.heap.ArenaAllocator.init(ws.gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const cfg = tools.config(ws.io, ws.gpa, ws.root);
    const saved = try state_mod.load(ws.io, aa, ws.root);
    var closed: std.ArrayList(Closed) = .empty;
    var moved: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (try forge.allRepos(ws, aa)) |repo| {
        const name = forge.displayName(repo);
        const branch = if (repo.name.len == 0) forge.headBranch(ws.io, aa, repo.path) orelse continue else repo.branch;
        const tip = forge.branchTip(ws.io, aa, repo.path, branch) orelse continue;
        const seen = saved.link_tips.map.get(name);
        if (seen) |s| if (std.mem.eql(u8, s, tip)) continue;
        if (seen != null and cfg.close_issues) {
            closeLanded(ws, &arena, repo, branch, seen.?, tip, &closed) catch |e| log.warn("commit links in {s}: {s}", .{ name, @errorName(e) });
        }
        try moved.put(aa, name, tip);
    }
    if (moved.count() > 0) try state_mod.update(ws.io, ws.gpa, ws.root, struct {
        fn f(a: std.mem.Allocator, s: *state_mod.State, m: *const std.StringArrayHashMapUnmanaged([]const u8)) !bool {
            var it = m.iterator();
            while (it.next()) |e| try s.link_tips.map.put(a, try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.*));
            return true;
        }
    }.f, &moved);
    return closed.items.len;
}

fn closeLanded(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: Repo, branch: []const u8, from: []const u8, to: []const u8, closed: *std.ArrayList(Closed)) !void {
    const aa = arena.allocator();
    const range = try std.fmt.allocPrint(aa, "{s}..{s}", .{ from, to });
    const text = forge.gitOut(ws.io, aa, &.{ "git", "-C", repo.path, "log", "--reverse", "--format=%H%x1f%s%x1f%B%x1e", range }) orelse return;
    var resolver: Resolver = .{ .ws = ws, .arena = arena, .repo = repo };
    const identity = try ws.identity(aa, repo);
    var commits = std.mem.tokenizeScalar(u8, text, 0x1e);
    while (commits.next()) |raw| {
        const entry = std.mem.trim(u8, raw, "\r\n");
        var fields = std.mem.splitScalar(u8, entry, 0x1f);
        const oid = fields.next() orelse continue;
        const subject = fields.next() orelse "";
        const body = fields.rest();
        for (try scan(aa, body)) |ref| {
            if (!ref.closes) continue;
            const hit = try resolver.resolve(ref.token) orelse continue;
            // re-read: an earlier commit of this batch may have closed it
            const now = try forge.readIssue(ws, arena, hit.repo, hit.issue.id) orelse continue;
            if (now.status != .open) continue;
            const url = if (ui.RoutablePage.repoCommitMessageRoute(identity, .object, oid, "")) |route| try route.toUrl(arena) else "";
            const comment = try std.fmt.allocPrint(aa, "Closed by commit [`{s}`]({s}) in {s} on `{s}`: {s}", .{ oid[0..@min(oid.len, 10)], url, forge.displayName(repo), branch, subject });
            forge.commentIssue(ws, hit.repo, hit.issue.id, comment, .closed) catch |e| {
                log.warn("can't close issue {s} for commit {s}: {t}", .{ hit.issue.id[0..8], oid[0..@min(oid.len, 10)], e });
                continue;
            };
            log.info("commit {s} in {s} closed issue {s}", .{ oid[0..@min(oid.len, 10)], forge.displayName(repo), hit.issue.id[0..8] });
            try closed.append(aa, .{ .repo = forge.displayName(hit.repo), .issue = hit.issue.id, .commit = oid });
        }
    }
}

//
// what references an issue
//

pub const CommitRef = struct { repo: []const u8, oid: []const u8, short: []const u8, summary: []const u8, href: []const u8, closes: bool, ci: ?status.Summary = null };
pub const ThreadRef = struct { repo: []const u8, title: []const u8, href: []const u8, status: []const u8 };

pub const References = struct {
    commits: []const CommitRef = &.{},
    patches: []const ThreadRef = &.{},
    stacks: []const ThreadRef = &.{},
    jobs: []const status.JobRef = &.{},

    pub fn empty(r: References) bool {
        return r.commits.len + r.patches.len + r.stacks.len + r.jobs.len == 0;
    }
};

// the commits (on any local branch, last two years), patches, stacks and CI
// jobs that reference issue `id` of `repo`. a workspace issue (in the events
// repo) is looked for in every repo. `client` (idlci, when it's running)
// adds the commits' CI balls and the jobs reported on the issue.
pub fn references(ws: *const Workspace, arena: *std.heap.ArenaAllocator, client: ?*idlci.Client, repo: Repo, id: []const u8) !References {
    const aa = arena.allocator();
    const workspace_issue = if (ws.events) |e| std.mem.eql(u8, e.path, repo.path) else false;
    const repos: []const Repo = if (workspace_issue) try forge.allRepos(ws, aa) else &.{repo};

    var commits: std.ArrayList(CommitRef) = .empty;
    var patches: std.ArrayList(ThreadRef) = .empty;
    for (repos) |r| {
        const identity = try ws.identity(aa, r);
        const out = forge.gitOut(ws.io, aa, &.{ "git", "-C", r.path, "log", "--exclude=cpull/*", "--exclude=haxy/*", "--branches", "--since=2.years", "-E", "-i", "--grep=#[0-9a-f]{6}", "-n", "400", "--format=%H%x1f%s%x1f%B%x1e" }) orelse "";
        var index: ?status.CommitIndex = null;
        var it = std.mem.tokenizeScalar(u8, out, 0x1e);
        while (it.next()) |raw| {
            var fields = std.mem.splitScalar(u8, std.mem.trim(u8, raw, "\r\n"), 0x1f);
            const oid = fields.next() orelse continue;
            const summary = fields.next() orelse "";
            const ref = try mentions(aa, fields.rest(), id) orelse continue;
            if (index == null) index = if (client) |c| commitIndex(c, forge.displayName(r)) else null;
            try commits.append(aa, .{
                .repo = forge.displayName(r),
                .oid = oid,
                .short = oid[0..@min(oid.len, 10)],
                .summary = summary,
                .href = if (ui.RoutablePage.repoCommitMessageRoute(identity, .object, oid, "")) |route| try route.toUrl(arena) else "",
                .closes = ref.closes,
                .ci = if (index) |x| x.get(oid) else null,
            });
            if (commits.items.len >= 50) break;
        }
        for (try forge.patches(ws, arena, r)) |p| {
            if (try mentions(aa, p.title, id) == null and try mentions(aa, p.description, id) == null) continue;
            try patches.append(aa, .{ .repo = forge.displayName(r), .title = p.title, .href = try forge.patchUrl(ws, arena, r, p.id), .status = p.status });
        }
    }
    var stacks: std.ArrayList(ThreadRef) = .empty;
    for (ws_mod.listStacks(ws, arena) catch &.{}) |s| {
        const ev = s.record.event;
        if (try mentions(aa, ev.title, id) == null and try mentions(aa, ev.description, id) == null) continue;
        try stacks.append(aa, .{ .repo = "", .title = ev.title, .href = try ui.Workspace.stackUrl(aa, &s.id), .status = @tagName(ev.status.kind()) });
    }
    var jobs: std.ArrayList(status.JobRef) = .empty;
    if (client) |c| {
        const saved = state_mod.load(ws.io, aa, ws.root) catch state_mod.State{};
        const ids = saved.issue_jobs.map.get(try state_mod.issueJobsKey(aa, forge.displayName(repo), id)) orelse &.{};
        // newest first, as many as the page shows
        var i = ids.len;
        while (i > 0 and jobs.items.len < 20) {
            i -= 1;
            const job = c.get(try std.fmt.allocPrint(aa, "/api/jobs/{d}", .{ids[i]})) catch continue;
            if (status.jobRefOfJob(c, job)) |ref| try jobs.append(aa, ref);
        }
    }
    return .{ .commits = commits.items, .patches = patches.items, .stacks = stacks.items, .jobs = jobs.items };
}

// idlci's CI per commit of a repo (GET /api/status/commits?repo=R)
pub fn commitIndex(client: *idlci.Client, repo: []const u8) ?status.CommitIndex {
    const path = std.fmt.allocPrint(client.a, "/api/status/commits?repo={s}", .{idlci.queryEscape(client.a, repo) catch return null}) catch return null;
    const v = client.get(path) catch return null;
    return status.parseCommitIndex(client, v);
}

test scan {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = try scan(a, "Fixes #a1b2c3d4, see #deadbeef00 and closes: #0123456789\nnot #abc or #abcdefg or x#abcdef or &#123456; or http://x/#abcdef1");
    try std.testing.expectEqual(@as(usize, 3), refs.len);
    try std.testing.expectEqualStrings("a1b2c3d4", refs[0].token);
    try std.testing.expect(refs[0].closes);
    try std.testing.expect(!refs[1].closes);
    try std.testing.expect(refs[2].closes);
    try std.testing.expect((try mentions(a, "resolved #a1b2c3", "a1b2c3d4e5f60718293a4b5c6d7e8f90")).?.closes);
    try std.testing.expect(try mentions(a, "#a1b2c4", "a1b2c3d4e5f60718293a4b5c6d7e8f90") == null);
    try std.testing.expect(!(try scan(a, "prefix #abcdef"))[0].closes);
}
