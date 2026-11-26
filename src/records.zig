// `cpull records PATH...`: the merged state of repos' issues, comments and
// stacks as json, for tools that read cpull's events without linking cpull
// (pull's `pull cpull ...` and its MCP tools). Replaying the event commits in
// order isn't enough once two histories have been merged: cpull merges each
// record field by field against the merge base (evt.merge), so after
// concurrent edits only cpull knows which value won. This prints that state
// from the repo's event cache (.git/cpull), brought up to date first.
//
//   [{"path": PATH,
//     "issues":   [{"id", "data": <the issue event's data>, "conflicted_fields"}],
//     "comments": [{"id", "data": <the comment event's data>}],
//     "stacks":   [{"id", "data": <the stack event's data>, "conflicted_fields"}]}]
//
// `data` is serialized like the event commits carry it, so a reader can parse
// both the same way. Removed records are left out. A path that can't be read
// gets `"error"` instead of the lists; a repo without events has empty lists.
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("event.zig");
const ui = @import("ui.zig");

pub const Options = struct {
    paths: []const []const u8,
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    options: Options,
    global_config_path: ?[]const u8,
    out: *std.Io.Writer,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var jw: std.json.Stringify = .{ .writer = out, .options = .{} };
    try jw.beginArray();
    for (options.paths) |p| {
        const path = try std.Io.Dir.path.resolve(aa, &.{ cwd, p });
        try jw.beginObject();
        try jw.objectField("path");
        try jw.write(path);
        writeRepo(io, gpa, &arena, path, global_config_path, &jw) catch |e| {
            try jw.objectField("error");
            try jw.write(@errorName(e));
        };
        try jw.endObject();
    }
    try jw.endArray();
    try out.writeByte('\n');
    try out.flush();
}

fn writeRepo(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    global_config_path: ?[]const u8,
    jw: *std.json.Stringify,
) !void {
    const src: ui.RepoSource = .{ .path = path, .repo_kind = .git, .global_config_path = global_config_path, .pull_identity = true };
    var any_repo = try rp.AnyRepo(.git, .{}).open(io, gpa, src.localInitOpts());
    defer any_repo.deinit(io, gpa);
    switch (any_repo) {
        inline else => |*repo| try writeRecords(repo.self_repo_opts, io, gpa, arena, repo, jw),
    }
}

fn writeRecords(
    comptime opts: rp.RepoOpts(.git),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(.git, opts),
    jw: *std.json.Stringify,
) !void {
    const DB = evt.EventDB(opts.hash);
    // gather everything first, so an error leaves no half-written lists
    var lists: [kinds.len]std.ArrayList(Row) = @splat(.empty);
    if (try repo.readRef(io, evt.events_ref) != null) {
        try evt.consume(.local, .repo, .git, opts, io, gpa, repo, evt.events_ref, &.{});
        if (try evt.LocalEventDB(opts.hash).openReadOnly(io, gpa, repo.core.repo_dir)) |db_| {
            var db = db_;
            defer db.deinit(io, gpa);
            if (evt.currentMomentFromDb(opts.hash, db.db)) |moment| {
                inline for (kinds, 0..) |kind, i| lists[i] = try rows(kind.T, DB, opts.hash, moment, arena);
            } else |_| {}
        }
    }
    inline for (kinds, 0..) |kind, i| {
        try jw.objectField(kind.name);
        try jw.beginArray();
        for (lists[i].items) |row| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(&row.id);
            try jw.objectField("data");
            try jw.beginWriteRaw();
            try jw.writer.writeAll(row.data);
            jw.endWriteRaw();
            if (kind.conflicts) {
                try jw.objectField("conflicted_fields");
                try jw.write(row.conflicted_fields);
            }
            try jw.endObject();
        }
        try jw.endArray();
    }
}

const Kind = struct { name: []const u8, T: type, conflicts: bool };
const kinds = [_]Kind{
    .{ .name = "issues", .T = evt.Issue, .conflicts = true },
    .{ .name = "comments", .T = evt.Comment, .conflicts = false },
    .{ .name = "stacks", .T = evt.Stack, .conflicts = true },
};

const Row = struct {
    id: [evt.event_id_size * 2]u8,
    // the event's data as json
    data: []const u8,
    conflicted_fields: []const u8 = "",
};

// every record of kind T that isn't removed, in id-set order
fn rows(
    comptime T: type,
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
) !std.ArrayList(Row) {
    const aa = arena.allocator();
    var out: std.ArrayList(Row) = .empty;
    const ids_cursor = try moment.getCursor(hash.hashInt(hash_kind, T.all_id_set_key)) orelse return out;
    const records_cursor = try moment.getCursor(hash.hashInt(hash_kind, T.record_map_key)) orelse return out;
    const ids = try DB.SortedSet(.read_only).init(ids_cursor);
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const conflicts: ?DB.SortedMap(.read_only) = if (@hasDecl(T, "conflicts_key"))
        if (try moment.getCursor(hash.hashInt(hash_kind, T.conflicts_key))) |c| try DB.SortedMap(.read_only).init(c) else null
    else
        null;

    var iter = try ids.iteratorFromIndex(0);
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(DB, cursor);
        const record_cursor = try records.getCursor(hash.hashInt(hash_kind, &id)) orelse continue;
        const record = try evt.read(T.Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
        if (record.removed) continue;
        var fields: []const u8 = "";
        if (conflicts) |map| if (try map.getCursor(&evt.orderKeyDesc(record.created_order, &id))) |entry_cursor| {
            const entry = try DB.HashMap(.read_only).init(entry_cursor);
            if (try entry.getCursor(hash.hashInt(hash_kind, evt.conflicted_fields_key))) |fields_cursor| {
                fields = try fields_cursor.readBytesAlloc(aa, null);
            }
        };
        try out.append(aa, .{
            .id = std.fmt.bytesToHex(id, .lower),
            .data = try std.json.Stringify.valueAlloc(aa, record.event, .{}),
            .conflicted_fields = fields,
        });
    }
    return out;
}
