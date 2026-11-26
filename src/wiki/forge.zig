//! The wiki and the forge, when cpull serves the wiki live (at /wiki/, see
//! serve.zig): JSON for the wiki's client script (wiki assets/forge.js) under
//! /wiki/_cpull/, and the right-click report menu's POST, which files a
//! report (src/report) straight away instead of copying a
//! `pull cpull report` command.
//!
//!   GET  /wiki/_cpull/page?repo=R[&file=F]  R's cpull page, open issues, and
//!                                            the open reports anchored to F
//!   GET  /wiki/_cpull/repos                  every repo's page and open issues
//!   POST /wiki/_cpull/report                 {repo, file, line, quote?, note?}
//!
//! None of it reaches the static site: the pages only call it when serve.zig
//! has put `<meta name="cpull-wiki">` in their head, which it does to the
//! pages it serves and never to dist/. web.zig routes here (this file needs
//! the workspace, so wiki.zig, the standalone generator, doesn't import it).
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const ws_mod = @import("../workspace.zig");
const report = @import("../report/report.zig");
const anchor_mod = @import("../report/anchor.zig");
const Workspace = ws_mod.Workspace;

pub const prefix = "/wiki/_cpull";

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, prefix) and (path.len == prefix.len or path[prefix.len] == '/');
}

const RepoInfo = struct {
    name: []const u8,
    url: []const u8,
    issues_url: []const u8,
    open_issues: usize = 0,
    open_reports: usize = 0,
    cloned: bool = false,
};

const PageReport = struct {
    id: []const u8,
    title: []const u8,
    line: u64,
    line_text: []const u8,
    quote: ?[]const u8,
    note: ?[]const u8,
    url: []const u8,
    created: []const u8,
};

const PageInfo = struct {
    workspace: []const u8,
    repo: ?RepoInfo,
    reports: []const PageReport,
};

/// Answer a request whose path is under `prefix`. `target` is path and query.
pub fn handle(io: std.Io, gpa: std.mem.Allocator, request: *std.http.Server.Request, ws: *Workspace, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    _ = io;
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |at| target[at + 1 ..] else "";
    const sub = path[prefix.len..];
    const method = request.head.method;

    if (std.mem.eql(u8, sub, "/page") and (method == .GET or method == .HEAD)) {
        const name = try queryParam(aa, query, "repo") orelse return respondError(request, .bad_request, "repo is required");
        const file = try queryParam(aa, query, "file");
        const repo = report.resolveRepo(ws, name) catch return respondJson(request, aa, .ok, PageInfo{ .workspace = ws.name, .repo = null, .reports = &.{} });
        var reports: std.ArrayList(PageReport) = .empty;
        const info = try repoInfo(ws, &arena, repo, file, &reports);
        return respondJson(request, aa, .ok, PageInfo{ .workspace = ws.name, .repo = info, .reports = reports.items });
    }
    if (std.mem.eql(u8, sub, "/repos") and (method == .GET or method == .HEAD)) {
        var out: std.ArrayList(RepoInfo) = .empty;
        for (ws.repos) |repo| try out.append(aa, try repoInfo(ws, &arena, repo, null, null));
        return respondJson(request, aa, .ok, out.items);
    }
    if (std.mem.eql(u8, sub, "/report") and method == .POST) {
        // json only: a cross-site form can't send it without a preflight
        const content_type = request.head.content_type orelse "";
        if (std.mem.indexOf(u8, content_type, "application/json") == null) return respondError(request, .unsupported_media_type, "send application/json");
        var buffer: [256]u8 = undefined;
        const body = request.readerExpectNone(&buffer).allocRemaining(aa, .limited(256 * 1024)) catch return respondError(request, .bad_request, "unreadable body");
        const New = struct { repo: []const u8, file: []const u8, line: u64, quote: ?[]const u8 = null, note: ?[]const u8 = null, title: ?[]const u8 = null };
        const new = std.json.parseFromSliceLeaky(New, aa, body, .{ .ignore_unknown_fields = true }) catch return respondError(request, .bad_request, "expected {repo, file, line, quote?, note?}");
        const filed = report.add(ws, &arena, .{
            .repo = new.repo,
            .file = new.file,
            .line = new.line,
            .quote = new.quote,
            .note = new.note,
            .title = new.title,
            .source = "wiki",
        }) catch |err| return respondError(request, .unprocessable_entity, describe(err));
        return respondJson(request, aa, .created, .{ .id = filed.id, .title = filed.title, .repo = filed.repo, .file = filed.file, .line = filed.line, .url = filed.url });
    }
    return respondError(request, .not_found, "no such wiki api");
}

/// The repo's cpull urls and open issue count; with `file` and `reports`,
/// the open reports anchored to that file too.
fn repoInfo(ws: *Workspace, arena: *std.heap.ArenaAllocator, repo: ws_mod.Repo, file: ?[]const u8, reports: ?*std.ArrayList(PageReport)) !RepoInfo {
    const aa = arena.allocator();
    const identity = try ws.identity(aa, repo);
    var info: RepoInfo = .{
        .name = if (repo.name.len == 0) "." else repo.name,
        .url = try aa.print("/{s}", .{identity}),
        .issues_url = try aa.print("/{s}/issues", .{identity}),
    };
    ws_mod.withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            const a = args.arena.allocator();
            args.info.cloned = true;
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            const DB = evt.EventDB(opts.hash);
            const ids = try anchor_mod.statusIds(DB, opts.hash, moment, args.arena, .open);
            args.info.open_issues = ids.len;
            const Subset = struct {
                removed: bool,
                created_timestamp: u64,
                event: struct { title: []const u8, description: []const u8, anchor: ?evt.Issue.Anchor },
            };
            for (ids) |id| {
                const record = (try evt.readRecordSubset(evt.Issue, Subset, DB, opts.hash, moment, args.arena, &id)) orelse continue;
                if (record.removed) continue;
                const anchor = record.event.anchor orelse continue;
                args.info.open_reports += 1;
                const list = args.reports orelse continue;
                const want = args.file orelse continue;
                if (!std.mem.eql(u8, anchor.file, want)) continue;
                const hex = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower));
                const route = ui.RoutablePage.repoThreadRoute(.issue, args.identity, hex) orelse continue;
                try list.append(a, .{
                    .id = hex,
                    .title = record.event.title,
                    .line = anchor.line,
                    .line_text = anchor.line_text,
                    .quote = anchor.quote,
                    .note = if (record.event.description.len == 0) null else record.event.description,
                    .url = try route.toUrl(args.arena),
                    .created = try report.formatTime(a, record.created_timestamp),
                });
            }
        }
    }.run, .{ .arena = arena, .info = &info, .identity = identity, .file = file, .reports = reports }) catch |err| switch (err) {
        // not cloned (yet), or not a git repo
        error.RepoNotFound, error.FileNotFound, error.NotDir => {},
        else => |e| return e,
    };
    if (reports) |list| std.mem.sort(PageReport, list.items, {}, struct {
        fn lessThan(_: void, a: PageReport, b: PageReport) bool {
            return a.line < b.line;
        }
    }.lessThan);
    return info;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.RepoNotFound => "no such repo in the pullfile",
        error.NoEventsRepo => "the workspace has no events repo",
        error.FileNotFound => "no such file",
        error.OutsideRepo => "the file is outside the repo",
        error.NoSuchLine => "the file has no such line",
        error.InvalidLineNumber => "lines start at 1",
        error.NoPullIdentity => "the repo has no user.name/user.email; serve the workspace with `pull cpull open`",
        error.LabelTooLong => "a label is too long",
        else => @errorName(err),
    };
}

fn respondJson(request: *std.http.Server.Request, aa: std.mem.Allocator, status: std.http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(aa, value, .{});
    try request.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn respondError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(.{ .@"error" = message }, .{}, &w) catch {};
    try request.respond(w.buffered(), .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// The decoded value of `key` in a query string, or null.
fn queryParam(aa: std.mem.Allocator, query: []const u8, key: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const raw = try aa.dupe(u8, pair[eq + 1 ..]);
        std.mem.replaceScalar(u8, raw, '+', ' ');
        return std.Uri.percentDecodeInPlace(raw);
    }
    return null;
}

test "forge paths" {
    try std.testing.expect(matches("/wiki/_cpull/page"));
    try std.testing.expect(matches("/wiki/_cpull"));
    try std.testing.expect(!matches("/wiki/_cpullx"));
    try std.testing.expect(!matches("/wiki/index.html"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try queryParam(arena.allocator(), "repo=fossify-ios%2Fcommons-ios&file=docs/a+b.md", "file");
    try std.testing.expectEqualStrings("docs/a b.md", v.?);
    try std.testing.expectEqualStrings("fossify-ios/commons-ios", (try queryParam(arena.allocator(), "repo=fossify-ios%2Fcommons-ios", "repo")).?);
    try std.testing.expect(try queryParam(arena.allocator(), "", "repo") == null);
}
