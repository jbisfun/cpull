// a change that spans several repos of a pull workspace, landed together. it
// lives in the workspace's events repo (the one holding pullfile.plist) and
// names one ordinary patch per member repo, so each repo's own tools still see
// its part. the members are opaque cross-repo references here: a server
// accepts them without the member repos, and only workspace mode resolves them.
const std = @import("std");
const evt = @import("../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

title: []const u8,
description: []const u8,
labels: []const u8, // space-separated
// one "<repo> <patch id>" line per member, the repo named as in the pullfile
members: []const u8,
status: Status = .open,

pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_timestamp: u64 = 0,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

pub const StatusKind = enum { open, closed, merged };

pub const Status = union(StatusKind) {
    open,
    closed,
    merged: Merged,

    // the commits the merge pinned: one "<repo> <oid>" line per member repo
    pub const Merged = struct { pins: []const u8 };

    pub fn kind(self: Status) StatusKind {
        return std.meta.activeTag(self);
    }
};

pub const Member = struct { repo: []const u8, patch_id: []const u8 };

pub const label_max_len = 64;
pub const member_max_count = 64;
pub const repo_name_max_len = 256;

pub const merge_policy: evt.MergePolicy = .field_conflicts;
pub const record_map_key = "event-id->stack";
pub const all_id_set_key = "stack-id-set";
pub const conflicts_key = "conflicted-stack-id->conflict";
pub const id_to_field_to_oid_key = "stack-id->field->oid";
pub const status_to_id_set_key = "status->stack-id-set";

pub fn labelIterator(labels: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, labels, ' ');
}

pub fn fieldsValid(title: []const u8, labels: []const u8) bool {
    if (!evt.titleValid(title)) return false;
    var label_iter = labelIterator(labels);
    while (label_iter.next()) |label| {
        if (label.len > label_max_len) return false;
    }
    return true;
}

// a pullfile repo name: relative, "/"-separated, no empty, "." or ".." segments
pub fn repoNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > repo_name_max_len) return false;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| if (c <= ' ' or c == 0x7f or c == '\\') return false;
    }
    return true;
}

pub const MemberIterator = struct {
    lines: std.mem.TokenIterator(u8, .scalar),

    pub fn next(self: *MemberIterator) error{InvalidStackMember}!?Member {
        const line = self.lines.next() orelse return null;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidStackMember;
        return .{ .repo = line[0..space], .patch_id = line[space + 1 ..] };
    }
};

pub fn memberIterator(members: []const u8) MemberIterator {
    return .{ .lines = std.mem.tokenizeScalar(u8, members, '\n') };
}

// the "<repo> <patch id>" lines `members` serialize to
pub fn formatMembers(allocator: std.mem.Allocator, members: []const Member) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (members, 0..) |member, i| {
        if (i > 0) try out.append(allocator, '\n');
        try out.print(allocator, "{s} {s}", .{ member.repo, member.patch_id });
    }
    return out.toOwnedSlice(allocator);
}

// the member a repo's line names, or null
pub fn memberOf(members: []const u8, repo: []const u8) ?Member {
    var iter = memberIterator(members);
    while (iter.next() catch return null) |member| {
        if (std.mem.eql(u8, member.repo, repo)) return member;
    }
    return null;
}

// the pinned oid of `repo` in a merged stack's pins, or null
pub fn pinOf(pins: []const u8, repo: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, pins, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..space], repo)) return line[space + 1 ..];
    }
    return null;
}

// one patch per repo, at least one member, every patch id a real event id
pub fn validateMembers(members: []const u8) !void {
    var count: usize = 0;
    var iter = memberIterator(members);
    while (try iter.next()) |member| {
        if (!repoNameValid(member.repo)) return error.InvalidStackMember;
        _ = evt.parseEventId(member.patch_id) catch return error.InvalidStackMember;
        count += 1;
        if (count > member_max_count) return error.TooManyStackMembers;
        // a repo listed twice would merge in an undefined order
        var rest = iter;
        while (try rest.next()) |other| {
            if (std.mem.eql(u8, other.repo, member.repo)) return error.DuplicateStackMember;
        }
    }
    if (count == 0) return error.EmptyStack;
}

// every pin names a member repo once, with a full object id
pub fn validatePins(comptime hash_kind: hash.HashKind, members: []const u8, pins: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, pins, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidStackPin;
        const repo = line[0..space];
        if (memberOf(members, repo) == null) return error.InvalidStackPin;
        evt.PatchRev.validateOid(hash_kind, line[space + 1 ..]) catch return error.InvalidStackPin;
        if (pinOf(lines.rest(), repo) != null) return error.InvalidStackPin;
        seen += 1;
    }
    if (seen == 0) return error.InvalidStackPin;
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    // the commit this event came from; null from `merge`
    event_oid: ?[]const u8,
) !void {
    const record_key = hash.hashInt(hash_kind, event_id);
    const records = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key)));
    const statuses = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, status_to_id_set_key)));
    const conflicts = try DB.SortedMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key)));
    const field_oid_map = try DB.HashMap(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key)));

    var existing_maybe: ?Record = null;
    const existing_cursor_maybe = try records.getCursor(record_key);
    if (existing_cursor_maybe) |cursor| {
        existing_maybe = try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(cursor));
    }

    var record = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_maybe);

    if (!fieldsValid(record.event.title, record.event.labels)) return error.InvalidStack;
    try validateMembers(record.event.members);
    switch (record.event.status) {
        .open, .closed => {},
        .merged => |merged| try validatePins(hash_kind, record.event.members, merged.pins),
    }

    if (existing_maybe) |existing| {
        record.created_order = existing.created_order;
        record.author_email = existing.author_email;
        record.created_timestamp = existing.created_timestamp;
        // a merged stack is history: its members and pins are what landed.
        // a merge of two histories (no oid) may still settle on either side.
        if (event_oid != null and existing.event.status.kind() == .merged and !record.removed) {
            if (!evt.fieldEqual(Status, existing.event.status, record.event.status)) return error.StackAlreadyMerged;
            if (!std.mem.eql(u8, existing.event.members, record.event.members)) return error.StackAlreadyMerged;
        }
        const existing_key = evt.orderKeyDesc(existing.created_order, event_id);
        if (event_oid != null or record.removed) _ = try conflicts.remove(&existing_key);
        if (!existing.removed) {
            const old_status = try statusSet(DB, statuses, existing.event.status.kind());
            _ = try old_status.remove(&existing_key);
        }
    }

    try evt.writeOid(Self, DB, hash_kind, field_oid_map, record_key, if (existing_maybe) |existing| existing.event else null, record.event, event_oid);

    const cursor = try records.putCursor(record_key);
    try evt.upsert(Record, DB, hash_kind, try DB.HashMap(.read_write).init(cursor), record);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .stack, existing_maybe, record);

    const key = evt.orderKeyDesc(record.created_order, event_id);
    if (existing_cursor_maybe == null) {
        const ids = try DB.SortedSet(.read_write).init(try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key)));
        try ids.put(&key);
    }

    if (!record.removed) {
        const status = try statusSet(DB, statuses, record.event.status.kind());
        try status.put(&key);
    }
}

// a field both sides changed is a conflict, except that a merge wins over an
// open or closed status as long as both agree on the members
pub fn resolveMerge(
    target: Self,
    parent: Self,
    merged: *Self,
    outcome: *[@typeInfo(Self).@"struct".field_names.len]evt.FieldMerge,
) void {
    const status_index = std.meta.fieldIndex(Self, "status") orelse @compileError("Stack.status not found");
    const members_index = std.meta.fieldIndex(Self, "members") orelse @compileError("Stack.members not found");
    if (outcome[status_index] != .conflicted or outcome[members_index] == .conflicted) return;
    if (target.status.kind() == .merged and parent.status.kind() != .merged) {
        merged.status = target.status;
        merged.members = target.members;
        outcome[status_index] = .kept;
    } else if (parent.status.kind() == .merged and target.status.kind() != .merged) {
        merged.status = parent.status;
        merged.members = parent.members;
        outcome[status_index] = .parent;
    }
}

fn statusSet(comptime DB: type, statuses: DB.SortedMap(.read_write), status: StatusKind) !DB.SortedSet(.read_write) {
    return DB.SortedSet(.read_write).init(try statuses.putCursor(@tagName(status)));
}

pub fn readById(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    id: *const [evt.event_id_size]u8,
) !?Record {
    const records_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, record_map_key)) orelse return null;
    const records = try DB.HashMap(.read_only).init(records_cursor);
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    return try evt.read(Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
}

pub const WithId = struct {
    id: [evt.event_id_size * 2]u8,
    record: Record,
    // the fields a sync left conflicted, space separated ("" = none)
    conflicted_fields: []const u8 = "",
};

// every stack that isn't removed, newest first
pub fn list(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
) ![]WithId {
    var out: std.ArrayList(WithId) = .empty;
    const ids_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, all_id_set_key)) orelse return out.items;
    const ids = try DB.SortedSet(.read_only).init(ids_cursor);
    const conflicts: ?DB.SortedMap(.read_only) = if (try haxy_moment.getCursor(hash.hashInt(hash_kind, conflicts_key))) |cursor| try DB.SortedMap(.read_only).init(cursor) else null;
    var iter = try ids.iteratorFromIndex(0);
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(DB, cursor);
        const record = (try readById(DB, hash_kind, haxy_moment, arena, &id)) orelse continue;
        if (record.removed) continue;
        var fields: []const u8 = "";
        if (conflicts) |map| if (try map.getCursor(&evt.orderKeyDesc(record.created_order, &id))) |entry_cursor| {
            const entry = try DB.HashMap(.read_only).init(entry_cursor);
            if (try entry.getCursor(hash.hashInt(hash_kind, evt.conflicted_fields_key))) |fields_cursor| {
                fields = try fields_cursor.readBytesAlloc(arena.allocator(), null);
            }
        };
        try out.append(arena.allocator(), .{ .id = std.fmt.bytesToHex(id, .lower), .record = record, .conflicted_fields = fields });
    }
    return out.items;
}

// write a stack event (a new stack, or `id`'s next state) to the repo's events
pub fn write(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
    stack: Self,
    author: evt.CommitAuthor,
) !void {
    if (!fieldsValid(stack.title, stack.labels)) return error.InvalidFields;
    try validateMembers(stack.members);
    try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .stack = stack },
    }});
}
