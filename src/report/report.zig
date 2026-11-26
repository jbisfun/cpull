// `cpull report`: line-anchored issues, the successor of radar
// (github.com/jbisfun/radar). A report is an ordinary issue in the repo it
// points at, with an `anchor` (evt.Issue.Anchor): the file, the 1-based line,
// that line's text, the narrower text selected, the commit, and where it was
// filed from. Reports therefore sync, merge and show like any other issue;
// this file is the CLI that files, lists, closes and migrates them over a
// pull workspace. pull (`pull cpull report`), its MCP tools, ycode-radar and
// the wiki's right-click menu all drive it.
//
//   cpull report REPO FILE LINE [-q QUOTE] [-n NOTE] [--title T] [--labels L] [--source S] [--json]
//   cpull report list [--all] [--json]
//   cpull report show ID
//   cpull report close ID / cpull report reopen ID
//   cpull report migrate RADAR_JSON      (the output of `radar list --all --json`)
//
// REPO is a pullfile repo, or "." for the workspace's events repo. ID is an
// issue id; a unique prefix will do.
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const ws_mod = @import("../workspace.zig");
const pullfile = @import("../pullfile.zig");
const anchor_mod = @import("anchor.zig");
const Workspace = ws_mod.Workspace;

pub const Action = enum { add, list, show, close, reopen, migrate };

pub const Options = struct {
    action: Action,
    // add: REPO FILE LINE; show/close/reopen: ID; migrate: FILE
    args: []const []const u8 = &.{},
    workspace_path: ?[]const u8 = null,
    quote: ?[]const u8 = null,
    note: ?[]const u8 = null,
    title: ?[]const u8 = null,
    labels: []const u8 = "",
    source: []const u8 = "cli",
    all: bool = false,
    json: bool = false,
};

// every report carries this label, so `label:report` lists them in the UI
pub const label = "report";
// reports migrated from radar.db also carry this one
pub const radar_label = "radar";
const title_max_len = 80;

// the action `cpull report ARGS...` names: a leading list/show/close/reopen/
// migrate with its arity, else an add with REPO FILE LINE (so a repo named
// "list" still works, since an add has three positionals)
pub fn parseAction(positional: []const []const u8) ?struct { Action, []const []const u8 } {
    if (positional.len == 3) return .{ .add, positional };
    if (positional.len == 0) return null;
    const action = std.meta.stringToEnum(Action, positional[0]) orelse return null;
    const rest = positional[1..];
    const ok = switch (action) {
        .add => false,
        .list => rest.len == 0,
        .show, .close, .reopen, .migrate => rest.len == 1,
    };
    return if (ok) .{ action, rest } else null;
}

// one report as `list --json` prints it
pub const Report = struct {
    id: []const u8,
    repo: []const u8,
    file: []const u8,
    line: u64,
    line_text: []const u8,
    quote: ?[]const u8,
    note: ?[]const u8,
    title: []const u8,
    status: []const u8,
    source: []const u8,
    commit: ?[]const u8,
    created: []const u8,
    author: ?[]const u8,
    url: []const u8,
    // seconds, for sorting; not printed
    created_timestamp: u64,

    pub fn jsonStringify(self: Report, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Report).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "created_timestamp")) {
                try jw.objectField(name);
                try jw.write(@field(self, name));
            }
        }
        try jw.endObject();
    }
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    options: Options,
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
    const ws = Workspace.load(io, gpa, aa, root, global_config_path) catch |e| {
        try err.print("can't read the pull workspace at {s}: {s}\n", .{ root, @errorName(e) });
        return error.HandledError;
    };
    dispatch(ws, &arena, options, out, err) catch |e| {
        switch (e) {
            error.HandledError => {},
            else => try err.print("cpull report {s}: {s}\n", .{ @tagName(options.action), describe(e) }),
        }
        return error.HandledError;
    };
    try out.flush();
}

fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.RepoNotFound => "no such repo in the pullfile (use \".\" for the workspace's events repo)",
        error.NoEventsRepo => "the workspace has no events repo (see cpull docs/workspace.md)",
        error.FileNotFound => "no such file",
        error.OutsideRepo => "the file is outside the repo",
        error.NoSuchLine => "the file has no such line",
        error.InvalidLine => "lines start at 1",
        error.ReportNotFound => "no report has that id",
        error.AmbiguousId => "that id prefix matches more than one report",
        error.NoPullIdentity => "the repo has no user.name/user.email; run it through pull (`pull cpull report ...`)",
        else => @errorName(e),
    };
}

fn dispatch(ws: *Workspace, arena: *std.heap.ArenaAllocator, options: Options, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    switch (options.action) {
        .add => {
            const line = std.fmt.parseInt(u64, options.args[2], 10) catch return error.InvalidLine;
            const report = try add(ws, arena, .{
                .repo = options.args[0],
                .file = options.args[1],
                .line = line,
                .quote = options.quote,
                .note = options.note,
                .title = options.title,
                .labels = options.labels,
                .source = options.source,
            });
            if (options.json) {
                try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, out);
                try out.writeByte('\n');
            } else try out.print("{s} {s}/{s}:{d}\n", .{ report.id[0..8], report.repo, report.file, report.line });
        },
        .list => {
            const reports = try list(ws, arena, options.all);
            if (options.json) {
                try std.json.Stringify.value(reports, .{ .whitespace = .indent_2 }, out);
                try out.writeByte('\n');
                return;
            }
            for (reports) |r| try writeText(out, r);
            if (reports.len == 0) try out.print("no {s}reports\n", .{if (options.all) "" else "open "});
        },
        .show => {
            const found = try find(ws, arena, options.args[0]);
            if (options.json) {
                try std.json.Stringify.value(found, .{ .whitespace = .indent_2 }, out);
                try out.writeByte('\n');
            } else {
                try writeText(out, found);
                try out.print("    {s}\n", .{found.url});
            }
        },
        .close, .reopen => {
            const status: evt.Issue.Status = if (options.action == .close) .closed else .open;
            const found = try setStatus(ws, arena, options.args[0], status);
            try out.print("{s} {s}\n", .{ found.id[0..8], if (status == .closed) "closed" else "reopened" });
        },
        .migrate => try migrate(ws, arena, options.args[0], out, err),
    }
}

fn writeText(out: *std.Io.Writer, r: Report) !void {
    try out.print("{s} {s}/{s}:{d}{s}  {s}\n    {s}\n", .{
        r.id[0..8],
        r.repo,
        r.file,
        r.line,
        if (std.mem.eql(u8, r.status, "closed")) " (closed)" else "",
        r.created,
        std.mem.trim(u8, r.line_text, " \t\r"),
    });
    if (r.note) |note| if (note.len > 0) try out.print("    {s}\n", .{note});
}

//
// filing
//

pub const New = struct {
    repo: []const u8,
    file: []const u8,
    line: u64,
    quote: ?[]const u8 = null,
    note: ?[]const u8 = null,
    title: ?[]const u8 = null,
    labels: []const u8 = "",
    source: []const u8 = "cli",
};

// the repo REPO names: a pullfile repo, or "." (also "" or "workspace") for
// the events repo
pub fn resolveRepo(ws: *const Workspace, name: []const u8) !ws_mod.Repo {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ws_mod.root_key)) return ws.events orelse error.NoEventsRepo;
    return ws.byName(std.mem.trimEnd(u8, name, "/")) orelse error.RepoNotFound;
}

// file a report: the line text is read from the work tree, and the commit is
// recorded when HEAD holds that same text at that line (so excerpts read at
// it line up)
pub fn add(ws: *Workspace, arena: *std.heap.ArenaAllocator, new: New) !Report {
    const aa = arena.allocator();
    const repo = try resolveRepo(ws, new.repo);
    if (new.line == 0) return error.InvalidLine;
    const file = try normalizePath(aa, new.file);
    const line_text = try readWorkLine(ws.io, aa, repo.path, file, new.line);

    const quote: ?[]const u8 = if (new.quote) |q| blk: {
        const trimmed = std.mem.trim(u8, q, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, std.mem.trim(u8, line_text, " \t\r"))) break :blk null;
        break :blk trimmed;
    } else null;
    const note = if (new.note) |n| std.mem.trim(u8, n, " \t\r\n") else "";

    var id_bytes: [evt.event_id_size]u8 = undefined;
    ws.io.random(&id_bytes);
    const id = std.fmt.bytesToHex(id_bytes, .lower);
    const labels = try joinLabels(aa, new.labels, &.{label});

    var commit: ?[]const u8 = null;
    try ws_mod.withRepo(ws, repo, true, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            const a = args.arena.allocator();
            // HEAD's commit, when its version of the file has the same text there
            if (try headOid(opts, w.io, r)) |head| {
                if (anchor_mod.readFile(.git, opts, r, w.io, args.arena, &head, args.file)) |lines| {
                    if (args.line <= lines.len and std.mem.eql(u8, lines[args.line - 1], args.line_text)) args.commit.* = try a.dupe(u8, &head);
                } else |_| {}
            }
            const issue: evt.Issue = .{
                .title = args.title,
                .description = args.note,
                .labels = args.labels,
                .anchor = .{ .file = args.file, .line = args.line, .line_text = args.line_text, .quote = args.quote, .commit = args.commit.*, .source = args.source },
            };
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{.{
                .id = args.id,
                .timestamp = @intCast(std.Io.Timestamp.now(w.io, .real).toSeconds()),
                .author = author,
                .event = .{ .issue = issue },
            }});
        }
    }.run, .{
        .arena = arena,
        .file = file,
        .line = new.line,
        .line_text = line_text,
        .quote = quote,
        .note = note,
        .labels = labels,
        .title = try deriveTitle(aa, new.title, note, file, new.line),
        .source = new.source,
        .id = id,
        .commit = &commit,
    });
    return .{
        .id = try aa.dupe(u8, &id),
        .repo = displayName(repo),
        .file = file,
        .line = new.line,
        .line_text = line_text,
        .quote = quote,
        .note = if (note.len == 0) null else note,
        .title = try deriveTitle(aa, new.title, note, file, new.line),
        .status = "open",
        .source = new.source,
        .commit = commit,
        .created = try formatTime(aa, @intCast(std.Io.Timestamp.now(ws.io, .real).toSeconds())),
        .author = null,
        .url = try issueUrl(ws, arena, repo, &id),
        .created_timestamp = @intCast(std.Io.Timestamp.now(ws.io, .real).toSeconds()),
    };
}

fn headOid(comptime opts: rp.RepoOpts(.git), io: std.Io, r: *rp.Repo(.git, opts)) !?[hash.hexLen(opts.hash)]u8 {
    var head_buffer: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
    const head = r.head(io, &head_buffer) catch return null;
    switch (head) {
        .ref => |ref| return try r.readRef(io, ref),
        .oid => |oid| {
            if (oid.len != hash.hexLen(opts.hash)) return null;
            return oid[0..comptime hash.hexLen(opts.hash)].*;
        },
    }
}

fn displayName(repo: ws_mod.Repo) []const u8 {
    return if (repo.name.len == 0) "." else repo.name;
}

// a repo-relative path without "./", doubled or trailing slashes
fn normalizePath(aa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.OutsideRepo;
        try parts.append(aa, part);
    }
    if (parts.items.len == 0) return error.FileNotFound;
    return std.mem.join(aa, "/", parts.items);
}

// line `line` (1-based) of the work-tree file, without its line ending. the
// real path must stay inside the repo, so symlinks can't escape it.
fn readWorkLine(io: std.Io, aa: std.mem.Allocator, repo_path: []const u8, file: []const u8, line: u64) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const repo_real = cwd.realPathFileAlloc(io, repo_path, aa) catch return error.RepoNotFound;
    const full = try std.Io.Dir.path.join(aa, &.{ repo_path, file });
    const real = cwd.realPathFileAlloc(io, full, aa) catch return error.FileNotFound;
    if (!std.mem.startsWith(u8, real, repo_real) or real.len <= repo_real.len or real[repo_real.len] != '/') return error.OutsideRepo;
    const text = cwd.readFileAlloc(io, real, aa, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.IsDir => return error.FileNotFound,
        else => |x| return x,
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u64 = 1;
    while (lines.next()) |l| : (n += 1) {
        if (n == line) {
            // a final newline doesn't start another line
            if (lines.index == null and l.len == 0) return error.NoSuchLine;
            return std.mem.trimEnd(u8, l, "\r");
        }
    }
    return error.NoSuchLine;
}

// the title: --title, else the note's first line (cut at title_max_len), else
// "file:line"
pub fn deriveTitle(aa: std.mem.Allocator, title: ?[]const u8, note: []const u8, file: []const u8, line: u64) ![]const u8 {
    if (title) |t| if (evt.titleValid(t)) return std.mem.trim(u8, t, " \t\r\n");
    const first = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, note, '\n')) |nl| note[0..nl] else note, " \t\r");
    if (first.len == 0) return aa.print("{s}:{d}", .{ file, line });
    if (first.len <= title_max_len) return first;
    // cut at a utf-8 boundary, then at the last space if there is one late enough
    var end: usize = title_max_len;
    while (end > 0 and (first[end] & 0xC0) == 0x80) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, first[0..end], ' ')) |space| if (space > title_max_len / 2) {
        end = space;
    };
    return aa.print("{s}…", .{std.mem.trimEnd(u8, first[0..end], " ,.;:")});
}

// `labels` (space- or comma-separated) plus `extra`, deduplicated, space-joined
fn joinLabels(aa: std.mem.Allocator, labels: []const u8, extra: []const []const u8) ![]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, labels, " ,");
    while (it.next()) |l| try appendUnique(aa, &items, l);
    for (extra) |l| try appendUnique(aa, &items, l);
    return std.mem.join(aa, " ", items.items);
}

fn appendUnique(aa: std.mem.Allocator, items: *std.ArrayList([]const u8), value: []const u8) !void {
    for (items.items) |item| if (std.mem.eql(u8, item, value)) return;
    if (value.len > evt.Issue.label_max_len) return error.LabelTooLong;
    try items.append(aa, value);
}

fn issueUrl(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: ws_mod.Repo, id: []const u8) ![]const u8 {
    const identity = try ws.identity(arena.allocator(), repo);
    const route = ui.RoutablePage.repoThreadRoute(.issue, identity, id) orelse return "";
    return route.toUrl(arena);
}

//
// reading
//

const Subset = struct {
    removed: bool,
    author_email: ?[]const u8,
    created_timestamp: u64,
    event: struct {
        title: []const u8,
        description: []const u8,
        status: evt.Issue.Status,
        anchor: ?evt.Issue.Anchor,
    },
};

// every repo a report can live in: the root events repo, then the pullfile's
fn allRepos(ws: *const Workspace, aa: std.mem.Allocator) ![]const ws_mod.Repo {
    if (ws.events) |e| if (e.name.len == 0) return std.mem.concat(aa, ws_mod.Repo, &.{ &.{e}, ws.repos });
    return ws.repos;
}

// the anchored issues of every repo, oldest first (open ones only unless `all`)
pub fn list(ws: *Workspace, arena: *std.heap.ArenaAllocator, all: bool) ![]Report {
    var reports: std.ArrayList(Report) = .empty;
    for (try allRepos(ws, arena.allocator())) |repo| {
        readRepo(ws, arena, repo, all, &reports) catch |e| switch (e) {
            // not cloned (yet), or not a git repo
            error.RepoNotFound, error.FileNotFound, error.NotDir => continue,
            else => |x| return x,
        };
    }
    std.mem.sort(Report, reports.items, {}, struct {
        fn lessThan(_: void, a: Report, b: Report) bool {
            if (a.created_timestamp != b.created_timestamp) return a.created_timestamp < b.created_timestamp;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    return reports.items;
}

fn readRepo(ws: *Workspace, arena: *std.heap.ArenaAllocator, repo: ws_mod.Repo, all: bool, out: *std.ArrayList(Report)) !void {
    try ws_mod.withRepo(ws, repo, false, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), _: evt.CommitAuthor, args: anytype) !void {
            const aa = args.arena.allocator();
            try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, r, evt.events_ref, &.{});
            var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return;
            defer db.deinit(w.io, w.gpa);
            const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return;
            const DB = evt.EventDB(opts.hash);
            const statuses: []const evt.Issue.Status = if (args.all) &.{ .open, .closed } else &.{.open};
            for (statuses) |status| {
                for (try anchor_mod.statusIds(DB, opts.hash, moment, args.arena, status)) |id| {
                    const record = (try evt.readRecordSubset(evt.Issue, Subset, DB, opts.hash, moment, args.arena, &id)) orelse continue;
                    if (record.removed) continue;
                    const anchor = record.event.anchor orelse continue;
                    const hex = try aa.dupe(u8, &std.fmt.bytesToHex(id, .lower));
                    try args.out.append(aa, .{
                        .id = hex,
                        .repo = displayName(args.repo),
                        .file = anchor.file,
                        .line = anchor.line,
                        .line_text = anchor.line_text,
                        .quote = anchor.quote,
                        .note = if (record.event.description.len == 0) null else record.event.description,
                        .title = record.event.title,
                        .status = @tagName(record.event.status),
                        .source = anchor.source orelse "",
                        .commit = anchor.commit,
                        .created = try formatTime(aa, record.created_timestamp),
                        .author = record.author_email,
                        .url = try issueUrl(w, args.arena, args.repo, hex),
                        .created_timestamp = record.created_timestamp,
                    });
                }
            }
        }
    }.run, .{ .arena = arena, .repo = repo, .all = all, .out = out });
}

// the report whose id starts with `prefix`, open or closed
pub fn find(ws: *Workspace, arena: *std.heap.ArenaAllocator, prefix: []const u8) !Report {
    const id = std.mem.trimStart(u8, prefix, "#");
    if (id.len == 0) return error.ReportNotFound;
    var found: ?Report = null;
    for (try list(ws, arena, true)) |r| {
        if (!std.mem.startsWith(u8, r.id, id)) continue;
        if (found != null) return error.AmbiguousId;
        found = r;
    }
    return found orelse error.ReportNotFound;
}

pub fn setStatus(ws: *Workspace, arena: *std.heap.ArenaAllocator, prefix: []const u8, status: evt.Issue.Status) !Report {
    const found = try find(ws, arena, prefix);
    const repo = try resolveRepo(ws, found.repo);
    const id_bytes = try evt.parseEventId(found.id);
    try ws_mod.withRepo(ws, repo, true, struct {
        fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
            try evt.Issue.update(.local, .git, opts, w.io, w.gpa, r, args.id, .{ .status = args.status }, author);
        }
    }.run, .{ .id = &id_bytes, .status = status });
    return found;
}

//
// migrating radar.db
//

// one report of `radar list --all --json`
const RadarReport = struct {
    number: u64,
    repo: []const u8,
    file: []const u8,
    line: u64,
    line_text: []const u8,
    quote: ?[]const u8 = null,
    note: ?[]const u8 = null,
    status: evt.Issue.Status,
    source: []const u8 = "cli",
    created: []const u8,
};

// the issue id a radar report migrates to: the first 16 bytes of
// sha256("radar:<number>:<created>"), so re-running a migration skips it
pub fn radarId(number: u64, created: []const u8) [evt.event_id_size * 2]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [32]u8 = undefined;
    hasher.update("radar:");
    hasher.update(std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable);
    hasher.update(":");
    hasher.update(created);
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest[0..evt.event_id_size].*, .lower);
}

// file every radar report as an anchored issue in its repo, keeping its
// status, note, quote, source and filing time. reports whose issue already
// exists are skipped, so this can run again.
fn migrate(ws: *Workspace, arena: *std.heap.ArenaAllocator, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    const aa = arena.allocator();
    const text = if (std.mem.eql(u8, path, "-"))
        try readStdin(ws.io, aa)
    else
        try std.Io.Dir.cwd().readFileAlloc(ws.io, path, aa, .limited(256 * 1024 * 1024));
    const radar = try std.json.parseFromSliceLeaky([]const RadarReport, aa, text, .{ .ignore_unknown_fields = true });

    var counts = struct { open: usize = 0, closed: usize = 0, present: usize = 0, unknown: usize = 0 }{};
    for (radar) |r| {
        const repo = resolveRepo(ws, r.repo) catch {
            try err.print("radar #{d}: no repo `{s}` in the pullfile; skipped\n", .{ r.number, r.repo });
            counts.unknown += 1;
            continue;
        };
        const id = radarId(r.number, r.created);
        const note = if (r.note) |n| std.mem.trim(u8, n, " \t\r\n") else "";
        const issue: evt.Issue = .{
            .title = try deriveTitle(aa, null, note, r.file, r.line),
            .description = note,
            .labels = try joinLabels(aa, "", &.{ label, radar_label }),
            .status = r.status,
            .anchor = .{ .file = r.file, .line = r.line, .line_text = r.line_text, .quote = r.quote, .source = r.source },
        };
        var wrote = false;
        try ws_mod.withRepo(ws, repo, true, struct {
            fn run(comptime opts: rp.RepoOpts(.git), w: *const Workspace, rr: *rp.Repo(.git, opts), author: evt.CommitAuthor, args: anytype) !void {
                try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, rr, evt.events_ref, &.{});
                if (try exists(opts, w, rr, args.arena, args.id)) return;
                // radar didn't record a commit: find the one the line was filed against
                var filed = args.issue;
                var anchor = filed.anchor.?;
                if (try anchor_mod.commitAt(.git, opts, rr, w.io, args.arena, anchor.file, anchor.line, anchor.line_text, args.timestamp)) |oid| {
                    anchor.commit = try args.arena.allocator().dupe(u8, &oid);
                }
                filed.anchor = anchor;
                try evt.consume(.local, .repo, .git, opts, w.io, w.gpa, rr, evt.events_ref, &.{.{
                    .id = args.id.*,
                    .timestamp = args.timestamp,
                    .author = author,
                    .event = .{ .issue = filed },
                }});
                args.wrote.* = true;
            }
        }.run, .{ .arena = arena, .id = &id, .issue = issue, .timestamp = parseTime(r.created) catch @as(u64, @intCast(std.Io.Timestamp.now(ws.io, .real).toSeconds())), .wrote = &wrote });
        if (!wrote) {
            counts.present += 1;
            continue;
        }
        switch (r.status) {
            .open => counts.open += 1,
            .closed => counts.closed += 1,
        }
        try out.print("radar #{d} -> {s} {s}/{s}:{d}{s}\n", .{ r.number, id[0..8], displayName(repo), r.file, r.line, if (r.status == .closed) " (closed)" else "" });
    }
    try out.print("migrated {d} of {d} radar reports ({d} open, {d} closed); {d} already present, {d} in unknown repos\n", .{ counts.open + counts.closed, radar.len, counts.open, counts.closed, counts.present, counts.unknown });
}

fn exists(comptime opts: rp.RepoOpts(.git), w: *const Workspace, r: *rp.Repo(.git, opts), arena: *std.heap.ArenaAllocator, id: *const [evt.event_id_size * 2]u8) !bool {
    var db = (try evt.LocalEventDB(opts.hash).openReadOnly(w.io, w.gpa, r.core.repo_dir)) orelse return false;
    defer db.deinit(w.io, w.gpa);
    const moment = evt.currentMomentFromDb(opts.hash, db.db) catch return false;
    const bytes = try evt.parseEventId(id);
    return null != try evt.readRecordSubset(evt.Issue, struct { removed: bool }, evt.EventDB(opts.hash), opts.hash, moment, arena, &bytes);
}

fn readStdin(io: std.Io, aa: std.mem.Allocator) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(aa, .limited(256 * 1024 * 1024));
}

//
// times
//

// "2026-11-18T03:14:54Z"
pub fn formatTime(aa: std.mem.Allocator, timestamp: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const day = seconds.getDaySeconds();
    return aa.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year.year, month.month.numeric(), month.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

// seconds since the epoch of an RFC 3339 time ("2026-11-18T03:14:54.99Z",
// "...+05:00"), fractions dropped
pub fn parseTime(text: []const u8) !u64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return error.InvalidTime;
    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(u8, text[5..7], 10);
    const day = try std.fmt.parseInt(u8, text[8..10], 10);
    const hour = try std.fmt.parseInt(i64, text[11..13], 10);
    const minute = try std.fmt.parseInt(i64, text[14..16], 10);
    const second = try std.fmt.parseInt(i64, text[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTime;
    var rest = text[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        rest = rest[i..];
    }
    var offset: i64 = 0;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {} else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const sign: i64 = if (rest[0] == '-') -1 else 1;
        offset = sign * ((try std.fmt.parseInt(i64, rest[1..3], 10)) * 3600 + (try std.fmt.parseInt(i64, rest[4..6], 10)) * 60);
    } else return error.InvalidTime;
    const total = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset;
    return std.math.cast(u64, total) orelse error.InvalidTime;
}

// days since 1970-01-01 of a proleptic Gregorian date: Howard Hinnant's
// days_from_civil (https://howardhinnant.github.io/date_algorithms.html)
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test parseTime {
    try std.testing.expectEqual(@as(u64, 0), try parseTime("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(u64, 1794971694), try parseTime("2026-11-18T03:14:54.992190370Z"));
    try std.testing.expectEqual(@as(u64, 1794971694), try parseTime("2026-11-17T22:14:54-05:00"));
    try std.testing.expectError(error.InvalidTime, parseTime("yesterday"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-11-18T03:14:54Z", try formatTime(arena.allocator(), 1794971694));
}

test parseAction {
    try std.testing.expectEqual(Action.add, parseAction(&.{ "list", "a.zig", "3" }).?[0]);
    try std.testing.expectEqual(Action.list, parseAction(&.{"list"}).?[0]);
    try std.testing.expectEqual(Action.close, parseAction(&.{ "close", "ab12" }).?[0]);
    try std.testing.expect(parseAction(&.{ "close", "a", "b", "c" }) == null);
    try std.testing.expect(parseAction(&.{"pull"}) == null);
}

test deriveTitle {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("src/a.zig:3", try deriveTitle(aa, null, "", "src/a.zig", 3));
    try std.testing.expectEqualStrings("panics", try deriveTitle(aa, null, "panics\nmore", "a", 1));
    try std.testing.expectEqualStrings("T", try deriveTitle(aa, "T", "note", "a", 1));
    const long = "The jobs sidebar has a fixed 260px width with pixel paddings, and Start/Stop/Restart/Unload are bordered text buttons.";
    const title = try deriveTitle(aa, null, long, "a", 1);
    try std.testing.expect(title.len <= title_max_len + "…".len);
    try std.testing.expect(std.mem.endsWith(u8, title, "…"));
}

test radarId {
    const a = radarId(17, "2026-11-18T03:14:54.992190370Z");
    try std.testing.expectEqualSlices(u8, &a, &radarId(17, "2026-11-18T03:14:54.992190370Z"));
    try std.testing.expect(!std.mem.eql(u8, &a, &radarId(16, "2026-11-18T03:14:54.992190370Z")));
}
