// cpull reports in the web UI: an anchored issue (evt.Issue.anchor, a line of
// code plus a note, formerly a radar report) shows a code excerpt on its issue
// page, and the files view marks the lines open anchored issues point at.
// ui/Repo.zig calls these once per repo page (never in the wasm build).
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const tr = xit.tree;
const df = xit.diff;
const obj = xit.object;
const hash = xit.hash;
const evt = @import("../event.zig");
const ui = @import("../ui.zig");

// the lines shown above and below the anchored line
pub const context_lines = 3;

// the code around an issue's anchor, read at the commit it was filed against
// (or the current head when it has none or that commit is gone)
pub const Excerpt = struct {
    file: []const u8,
    // the anchored line, 1-based, where it is in the excerpt's revision
    line: u64,
    // the line number recorded when the issue was filed
    filed_line: u64,
    // the 1-based number of lines[0]
    first: u64,
    lines: []const []const u8,
    // the commit the excerpt was read at, and the ref the files view links
    // it by (the head's branch, url-encoded, or the commit itself)
    commit: []const u8 = "",
    ref_kind: ui.RoutablePage.RefOrOid = .object,
    ref_value: []const u8 = "",
    // whether that is the anchor's own commit, rather than the head
    at_filed_commit: bool = false,
    // the line text no longer matches what was filed, and wasn't found nearby
    changed: bool = false,
};

// one open anchored issue pointing into the viewed directory
pub const FileAnchor = struct {
    // path relative to the repo
    file: []const u8,
    line: u64,
    line_text: []const u8,
    id: []const u8,
    title: []const u8,
};

const Subset = struct { event: struct { title: []const u8, status: evt.Issue.Status, anchor: ?evt.Issue.Anchor } };

// the open anchored issues whose file lies directly in `dir` ("" = the root),
// read from the repo's consumed event db
pub fn fileAnchors(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    dir: []const u8,
) ![]const FileAnchor {
    const aa = arena.allocator();
    const gpa = arena.child_allocator;
    const DB = evt.EventDB(repo_opts.hash);
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, gpa, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return &.{}
    else
        evt.currentMoment(repo_opts, repo)) catch return &.{};

    var out: std.ArrayList(FileAnchor) = .empty;
    for (try statusIds(DB, repo_opts.hash, moment, arena, .open)) |id| {
        const record = (try evt.readRecordSubset(evt.Issue, Subset, DB, repo_opts.hash, moment, arena, &id)) orelse continue;
        const anchor = record.event.anchor orelse continue;
        const parent = std.Io.Dir.path.dirnamePosix(anchor.file) orelse "";
        if (!std.mem.eql(u8, parent, dir)) continue;
        try out.append(aa, .{
            .file = anchor.file,
            .line = anchor.line,
            .line_text = anchor.line_text,
            .id = try aa.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
            .title = record.event.title,
        });
    }
    return out.items;
}

// the ids in the issues' `status` set, newest first
pub fn statusIds(comptime DB: type, comptime hash_kind: hash.HashKind, moment: DB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, status: evt.Issue.Status) ![]const [evt.event_id_size]u8 {
    var out: std.ArrayList([evt.event_id_size]u8) = .empty;
    const map_cursor = try moment.getCursor(hash.hashInt(hash_kind, evt.Issue.status_to_id_set_key)) orelse return out.items;
    const map = try DB.SortedMap(.read_only).init(map_cursor);
    const set_cursor = try map.getCursor(@tagName(status)) orelse return out.items;
    const set = try DB.SortedSet(.read_only).init(set_cursor);
    var iter = try set.iteratorFromIndex(0);
    while (try iter.next()) |cursor| try out.append(arena.allocator(), try evt.readOrderKeyId(DB, cursor));
    return out.items;
}

// the excerpt for `anchor`, or null when its file can't be read at the
// anchor's commit or the head
pub fn excerpt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    anchor: evt.Issue.Anchor,
) !?Excerpt {
    const aa = arena.allocator();
    const hex_len = comptime hash.hexLen(repo_opts.hash);
    // the filed commit first, since the line number refers to it
    if (anchor.commit) |commit| if (commit.len == hex_len) {
        if (readFile(repo_kind, repo_opts, repo, io, arena, commit[0..hex_len], anchor.file)) |lines| {
            var result = window(anchor, lines, anchor.line, try aa.dupe(u8, commit), true);
            result.ref_value = result.commit;
            return result;
        } else |_| {}
    };
    const head = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, null, "")) orelse return null;
    const lines = readFile(repo_kind, repo_opts, repo, io, arena, &head.oid, anchor.file) catch return null;
    // the line may have moved since: look for its text nearest the old number
    const line = relocate(lines, anchor.line, anchor.line_text);
    var result = window(anchor, lines, line orelse anchor.line, try aa.dupe(u8, &head.oid), false);
    result.changed = line == null and anchor.line_text.len > 0;
    result.ref_kind = head.ref_or_oid;
    result.ref_value = head.value;
    return result;
}

fn window(anchor: evt.Issue.Anchor, lines: []const []const u8, line: u64, commit: []const u8, at_filed_commit: bool) Excerpt {
    const index: usize = @intCast(@min(line -| 1, lines.len));
    const start = index -| context_lines;
    const end = @min(lines.len, index + context_lines + 1);
    return .{
        .file = anchor.file,
        .line = line,
        .filed_line = anchor.line,
        .first = start + 1,
        .lines = lines[start..end],
        .commit = commit,
        .at_filed_commit = at_filed_commit,
    };
}

// the 1-based line holding `text` (compared without surrounding whitespace)
// nearest `line`, or null when no line does
pub fn relocate(lines: []const []const u8, line: u64, text: []const u8) ?u64 {
    const want = std.mem.trim(u8, text, " \t\r");
    if (want.len == 0) return if (line >= 1 and line <= lines.len) line else null;
    const start: usize = @intCast(@min(line -| 1, lines.len));
    var distance: usize = 0;
    while (distance <= lines.len) : (distance += 1) {
        if (start + distance < lines.len and std.mem.eql(u8, std.mem.trim(u8, lines[start + distance], " \t\r"), want)) return start + distance + 1;
        if (distance > 0 and distance <= start and std.mem.eql(u8, std.mem.trim(u8, lines[start - distance], " \t\r"), want)) return start - distance + 1;
        if (start + distance >= lines.len and distance > start) break;
    }
    return null;
}

// every line of the committed file `path` at `commit`, in the arena
pub fn readFile(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    commit: *const [hash.hexLen(repo_opts.hash)]u8,
    path: []const u8,
) ![]const []const u8 {
    const aa = arena.allocator();
    const gpa = arena.child_allocator;
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var tree_dir = try tr.TreeDir(repo_kind, repo_opts).init(state, io, gpa, commit, path);
    defer tree_dir.deinit();
    const name = tree_dir.file_name orelse return error.NotAFile;
    const entry = tree_dir.entries.get(name) orelse return error.NotAFile;
    var line_iter = try df.LineIterator(repo_kind, repo_opts).initFromOid(state, io, gpa, path, &entry.oid, entry.mode);
    defer line_iter.deinit();
    if (line_iter.source == .binary) return error.BinaryFile;
    var total = line_iter.count();
    // a final newline ends the last line rather than starting another
    if (total > 0 and (try line_iter.get(total - 1)).len == 0) total -= 1;
    const lines = try aa.alloc([]const u8, total);
    for (lines, 0..) |*line, i| line.* = try aa.dupe(u8, try line_iter.get(i));
    return lines;
}

// the commit on HEAD's first-parent line that a line filed at `timestamp`
// referred to: the newest commit no newer than it whose `path` holds `text` at
// `line`, looking a few commits further back when that one doesn't (the line
// may have been filed against uncommitted work). null when none does.
pub fn commitAt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    line: u64,
    text: []const u8,
    timestamp: u64,
) !?[hash.hexLen(repo_opts.hash)]u8 {
    const max_walk = 20000;
    const max_older = 50;
    const gpa = arena.child_allocator;
    const head = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, arena.allocator(), null, "")) orelse return null;
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var oid = head.oid;
    var older: usize = 0;
    var walked: usize = 0;
    while (walked < max_walk) : (walked += 1) {
        var commit = obj.Object(repo_kind, repo_opts).initCommit(state, io, gpa, &oid) catch return null;
        defer commit.deinit();
        const metadata = commit.content.commit.metadata;
        if (metadata.timestamp <= timestamp) {
            if (readFile(repo_kind, repo_opts, repo, io, arena, &oid, path)) |lines| {
                if (line >= 1 and line <= lines.len and std.mem.eql(u8, lines[line - 1], text)) return oid;
            } else |_| {}
            older += 1;
            if (older > max_older) return null;
        }
        oid = (metadata.firstParent() orelse return null).*;
    }
    return null;
}

test relocate {
    const lines = [_][]const u8{ "a", "  b", "c", "b", "d" };
    try std.testing.expectEqual(@as(?u64, 2), relocate(&lines, 2, "b"));
    try std.testing.expectEqual(@as(?u64, 4), relocate(&lines, 5, "b"));
    try std.testing.expectEqual(@as(?u64, 1), relocate(&lines, 3, "a"));
    try std.testing.expectEqual(@as(?u64, null), relocate(&lines, 3, "z"));
    try std.testing.expectEqual(@as(?u64, 3), relocate(&lines, 3, ""));
}
