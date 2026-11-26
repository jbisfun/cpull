// reports: line-anchored issues. A report is an ordinary issue in the repo
// it points at, with an `anchor` (evt.Issue.Anchor): the file, the 1-based
// line, that line's text, the narrower text selected, the commit, and where
// it was filed from. Reports therefore sync, merge and show like any other
// issue. Capturing and tracking them is radar's (github.com/jbisfun/radar,
// over cpull's /api); this file reads them for cpull's own pages and its
// `GET /api/reports` (src/api.zig), and backs the files view's "report this
// line" form (web.zig).
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

// every report carries this label, so `label:report` lists them in the UI
pub const label = "report";
const title_max_len = 80;

// one report as `GET /api/reports` (and radar) print it
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

// the repo REPO names: a pullfile repo, or "." (also "" or "workspace") for
// the events repo
pub fn resolveRepo(ws: *const Workspace, name: []const u8) !ws_mod.Repo {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ws_mod.root_key)) return ws.events orelse error.NoEventsRepo;
    return ws.byName(std.mem.trimEnd(u8, name, "/")) orelse error.RepoNotFound;
}

pub fn displayName(repo: ws_mod.Repo) []const u8 {
    return if (repo.name.len == 0) "." else repo.name;
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
pub fn joinLabels(aa: std.mem.Allocator, labels: []const u8, extra: []const []const u8) ![]const u8 {
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

pub fn issueUrl(ws: *const Workspace, arena: *std.heap.ArenaAllocator, repo: ws_mod.Repo, id: []const u8) ![]const u8 {
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
