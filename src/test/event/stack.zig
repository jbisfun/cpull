const std = @import("std");
const evt = @import("../../event.zig");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;

const author = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };
const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
const Repo = rp.Repo(.xit, repo_opts);

const patch_a = "0123456789abcdef0123456789abcdef";
const patch_b = "fedcba9876543210fedcba9876543210";
const members = "core " ++ patch_a ++ "\ngroup/app " ++ patch_b;

fn stackEvent(id: [evt.event_id_size * 2]u8, stack: ?evt.Stack) evt.EventWithId {
    return .{ .id = id, .author = author, .event = .{ .stack = stack } };
}

const Oid = [hash.hexLen(repo_opts.hash)]u8;

fn commitEvent(repo: *Repo, ref: rf.Ref, parent: *const Oid, event: evt.EventWithId) !Oid {
    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    try std.json.Stringify.value(event, .{}, &json.writer);
    const parents = [_]Oid{parent.*};
    return repo.commitAtRef(std.testing.io, std.testing.allocator, .{ .message = json.written(), .parent_oids = &parents }, null, ref);
}

fn readStack(repo: *Repo, arena: *std.heap.ArenaAllocator, id: *const [evt.event_id_size]u8) !evt.Stack.Record {
    const moment = try evt.currentMoment(repo_opts, repo);
    return (try evt.Stack.readById(Repo.DB, repo_opts.hash, moment, arena, id)) orelse error.NotFound;
}

test "stack event json" {
    const allocator = std.testing.allocator;
    const id: [evt.event_id_size * 2]u8 = "00112233445566778899aabbccddeeff".*;
    const open_json = try std.json.Stringify.valueAlloc(allocator, stackEvent(id, .{ .title = "t", .description = "d", .labels = "x", .members = members }), .{});
    defer allocator.free(open_json);
    try std.testing.expectEqualStrings(
        \\{"id":"00112233445566778899aabbccddeeff","kind":"stack","data":{"title":"t","description":"d","labels":"x","members":"core 0123456789abcdef0123456789abcdef\ngroup/app fedcba9876543210fedcba9876543210","status":{"open":{}}}}
    , open_json);
    const merged_json = try std.json.Stringify.valueAlloc(allocator, stackEvent(id, .{ .title = "t", .description = "", .labels = "", .members = "core " ++ patch_a, .status = .{ .merged = .{ .pins = "core 0000000000000000000000000000000000000001" } } }), .{});
    defer allocator.free(merged_json);
    try std.testing.expect(std.mem.indexOf(u8, merged_json, "\"status\":{\"merged\":{\"pins\":\"core 0000000000000000000000000000000000000001\"}}") != null);

    // the member list helpers agree with the wire format
    try std.testing.expectEqualStrings(patch_b, evt.Stack.memberOf(members, "group/app").?.patch_id);
    try std.testing.expectEqual(null, evt.Stack.memberOf(members, "group"));
    const formatted = try evt.Stack.formatMembers(allocator, &.{ .{ .repo = "core", .patch_id = patch_a }, .{ .repo = "group/app", .patch_id = patch_b } });
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings(members, formatted);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000001", evt.Stack.pinOf("core 0000000000000000000000000000000000000001", "core").?);
}

test "stack member validation" {
    try evt.Stack.validateMembers(members);
    try std.testing.expectError(error.EmptyStack, evt.Stack.validateMembers(""));
    try std.testing.expectError(error.InvalidStackMember, evt.Stack.validateMembers("core"));
    try std.testing.expectError(error.InvalidStackMember, evt.Stack.validateMembers("core xyz"));
    try std.testing.expectError(error.InvalidStackMember, evt.Stack.validateMembers("../core " ++ patch_a));
    try std.testing.expectError(error.InvalidStackMember, evt.Stack.validateMembers("/core " ++ patch_a));
    try std.testing.expectError(error.InvalidStackMember, evt.Stack.validateMembers("a//b " ++ patch_a));
    try std.testing.expectError(error.DuplicateStackMember, evt.Stack.validateMembers("core " ++ patch_a ++ "\ncore " ++ patch_b));
    try evt.Stack.validatePins(.sha1, members, "core 0000000000000000000000000000000000000001\ngroup/app 0000000000000000000000000000000000000002");
    try std.testing.expectError(error.InvalidStackPin, evt.Stack.validatePins(.sha1, members, "other 0000000000000000000000000000000000000001"));
    try std.testing.expectError(error.InvalidStackPin, evt.Stack.validatePins(.sha1, members, "core 1234"));
    try std.testing.expectError(error.InvalidStackPin, evt.Stack.validatePins(.sha1, members, "core 0000000000000000000000000000000000000001\ncore 0000000000000000000000000000000000000001"));
}

test "stack consume, merge and field conflicts" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(temp_path);
    var repo = try Repo.init(io, allocator, .{ .path = temp_path });
    defer repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const id_bytes: [evt.event_id_size]u8 = @splat(0x5a);
    const id = std.fmt.bytesToHex(id_bytes, .lower);
    const base: evt.Stack = .{ .title = "land the api", .description = "two repos", .labels = "api", .members = members };

    // a new stack lands open, listed and indexed by kind
    try evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{stackEvent(id, base)});
    {
        const record = try readStack(&repo, &arena, &id_bytes);
        try std.testing.expectEqual(.open, record.event.status.kind());
        try std.testing.expectEqualStrings(members, record.event.members);
        try std.testing.expectEqualStrings(author.email, record.author_email.?);
        const moment = try evt.currentMoment(repo_opts, &repo);
        const listed = try evt.Stack.list(Repo.DB, repo_opts.hash, moment, &arena);
        try std.testing.expectEqual(1, listed.len);
        try std.testing.expectEqualStrings(&id, &listed[0].id);
    }

    // invalid members are rejected with the whole event
    {
        var invalid = base;
        invalid.members = "core nothex";
        try std.testing.expectError(error.InvalidStackMember, evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{stackEvent(id, invalid)}));
        invalid = base;
        invalid.status = .{ .merged = .{ .pins = "nope 0000000000000000000000000000000000000001" } };
        try std.testing.expectError(error.InvalidStackPin, evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{stackEvent(id, invalid)}));
        try std.testing.expectEqualStrings("land the api", (try readStack(&repo, &arena, &id_bytes)).event.title);
    }

    // two histories edit the title differently: a field conflict, ours stays live
    const fork_point = (try repo.readRef(io, evt.events_ref)).?;
    const other_ref: rf.Ref = .{ .kind = .head, .name = "haxy/other" };
    var ours = base;
    ours.title = "land the api (ours)";
    var theirs = base;
    theirs.title = "land the api (theirs)";
    theirs.labels = "api urgent";
    _ = try commitEvent(&repo, evt.events_ref, &fork_point, stackEvent(id, ours));
    _ = try commitEvent(&repo, other_ref, &fork_point, stackEvent(id, theirs));
    {
        var switched = try repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer switched.deinit();
        var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_ref }} } } }, null);
        defer merge.deinit();
        try std.testing.expect(.success == merge.result);
    }
    try evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{});
    {
        const record = try readStack(&repo, &arena, &id_bytes);
        try std.testing.expectEqualStrings("land the api (ours)", record.event.title);
        // only their side changed the labels, so theirs carry over
        try std.testing.expectEqualStrings("api urgent", record.event.labels);
        const moment = try evt.currentMoment(repo_opts, &repo);
        const listed = try evt.Stack.list(Repo.DB, repo_opts.hash, moment, &arena);
        try std.testing.expectEqualStrings("title", listed[0].conflicted_fields);
    }

    // any new event settles the conflict
    var resolved = base;
    resolved.title = "land the api";
    resolved.labels = "api urgent";
    try evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{stackEvent(id, resolved)});
    {
        const moment = try evt.currentMoment(repo_opts, &repo);
        try std.testing.expectEqualStrings("", (try evt.Stack.list(Repo.DB, repo_opts.hash, moment, &arena))[0].conflicted_fields);
    }

    // a merge on one side and a close on the other: the merge wins whole
    const fork_point2 = (try repo.readRef(io, evt.events_ref)).?;
    var merged = resolved;
    merged.status = .{ .merged = .{ .pins = "core 0000000000000000000000000000000000000001\ngroup/app 0000000000000000000000000000000000000002" } };
    var closed = resolved;
    closed.status = .closed;
    _ = try commitEvent(&repo, evt.events_ref, &fork_point2, stackEvent(id, closed));
    _ = try commitEvent(&repo, other_ref, &fork_point2, stackEvent(id, merged));
    {
        var switched = try repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer switched.deinit();
        var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_ref }} } } }, null);
        defer merge.deinit();
        try std.testing.expect(.success == merge.result);
    }
    try evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{});
    {
        const record = try readStack(&repo, &arena, &id_bytes);
        try std.testing.expectEqual(.merged, record.event.status.kind());
        try std.testing.expectEqualStrings("0000000000000000000000000000000000000002", evt.Stack.pinOf(record.event.status.merged.pins, "group/app").?);
        const moment = try evt.currentMoment(repo_opts, &repo);
        try std.testing.expectEqualStrings("", (try evt.Stack.list(Repo.DB, repo_opts.hash, moment, &arena))[0].conflicted_fields);
    }

    // a merged stack can't be reopened or have its members changed
    var reopened = merged;
    reopened.status = .open;
    try std.testing.expectError(error.StackAlreadyMerged, evt.consume(.local, .repo, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{stackEvent(id, reopened)}));

    // a repo role allows stacks, the fork role doesn't
    try std.testing.expectError(error.EventKindNotAllowed, evt.consume(.local, .fork, .xit, repo_opts, io, allocator, &repo, evt.events_ref, &.{stackEvent(id, resolved)}));
}
