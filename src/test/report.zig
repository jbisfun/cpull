// reports: line-anchored issues (src/report/), filed the way cpull's /api
// files them for radar, over a scratch pull workspace
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const ws = @import("../workspace.zig");
const report = @import("../report/report.zig");
const forge = @import("../forge.zig");
const anchor = @import("../report/anchor.zig");

const GitRepo = rp.Repo(.git, .{});
const ident = "alice <alice@example.test>";

const pullfile_text =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\<key>repos</key>
    \\<array>
    \\<dict><key>name</key><string>core</string><key>branch</key><string>master</string></dict>
    \\</array>
    \\</dict>
    \\</plist>
;

const source_text = "const a = 1;\nconst b = 2;\nfn main() void {}\n";

fn pinIdentity(io: std.Io, allocator: std.mem.Allocator, repo: *GitRepo) !void {
    try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "alice" });
    try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "alice@example.test" });
}

test "an issue without an anchor serializes as before" {
    const allocator = std.testing.allocator;
    const plain: evt.Issue = .{ .title = "t", .description = "d", .labels = "a b" };
    const json = try std.json.Stringify.valueAlloc(allocator, plain, .{});
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"title\":\"t\",\"description\":\"d\",\"labels\":\"a b\",\"status\":\"open\"}", json);

    const anchored: evt.Issue = .{ .title = "t", .description = "", .labels = "report", .anchor = .{ .file = "src/a.zig", .line = 3, .line_text = "x", .source = "cli" } };
    const json2 = try std.json.Stringify.valueAlloc(allocator, anchored, .{});
    defer allocator.free(json2);
    try std.testing.expectEqualStrings("{\"title\":\"t\",\"description\":\"\",\"labels\":\"report\",\"status\":\"open\",\"anchor\":{\"file\":\"src/a.zig\",\"line\":3,\"line_text\":\"x\",\"source\":\"cli\"}}", json2);

    // both parse back, the plain one with no anchor
    const parsed = try std.json.parseFromSlice(evt.Issue, allocator, json2, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 3), parsed.value.anchor.?.line);
    try std.testing.expectEqual(null, parsed.value.anchor.?.quote);
    const parsed_plain = try std.json.parseFromSlice(evt.Issue, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed_plain.deinit();
    try std.testing.expectEqual(null, parsed_plain.value.anchor);
}

test "anchored issues file, list, close and keep their id" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const root = try temp.dir.realPathFileAlloc(io, ".", aa);
    {
        const f = try temp.dir.createFile(io, "pullfile.plist", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, pullfile_text);
    }
    const config_path = try std.Io.Dir.path.join(aa, &.{ root, "gitconfig" });
    {
        const f = try temp.dir.createFile(io, "gitconfig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "[user]\n\tname = global\n\temail = global@example.test\n");
    }
    {
        var root_repo = try GitRepo.init(io, allocator, .{ .path = root });
        defer root_repo.deinit(io, allocator);
        try pinIdentity(io, allocator, &root_repo);
    }
    {
        var repo = try GitRepo.init(io, allocator, .{ .path = try std.Io.Dir.path.join(aa, &.{ root, "core" }) });
        defer repo.deinit(io, allocator);
        try pinIdentity(io, allocator, &repo);
        try repo.core.work_dir.createDirPath(io, "src");
        const f = try repo.core.work_dir.createFile(io, "src/a.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, source_text);
        try repo.add(io, allocator, &.{"src/a.zig"});
        _ = try repo.commit(io, allocator, .{ .message = "base", .author = ident, .committer = ident });
    }

    const workspace = try ws.Workspace.load(io, allocator, aa, root, config_path);
    const core = workspace.byName("core").?;

    // filed with an anchor (radar read the line and the commit), as POST /api/issues does
    const head = blk: {
        var repo = try GitRepo.open(io, allocator, .{ .path = core.path });
        defer repo.deinit(io, allocator);
        var buf: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
        const ref = (try repo.head(io, &buf)).ref;
        break :blk (try repo.readRef(io, ref)).?;
    };
    const id = try forge.fileIssueWith(workspace, core, .{
        .title = "b is wrong",
        .description = "b is wrong\nbecause",
        .labels = "report",
        .anchor = .{ .file = "src/a.zig", .line = 2, .line_text = "const b = 2;", .quote = "b = 2", .commit = &head, .source = "cli" },
    });
    // "." files into the events repo, here the workspace root
    _ = try forge.fileIssueWith(workspace, try report.resolveRepo(workspace, "."), .{ .title = "pullfile.plist:1", .labels = "report", .anchor = .{ .file = "pullfile.plist", .line = 1, .line_text = "<?xml" } });
    // an unanchored issue isn't a report
    _ = try forge.fileIssue(workspace, core, "plain", "", "");

    {
        const open = try report.list(workspace, &arena, false);
        try std.testing.expectEqual(2, open.len);
        const found = try report.find(workspace, &arena, id[0..6]);
        try std.testing.expectEqualStrings("core", found.repo);
        try std.testing.expectEqualStrings("b is wrong\nbecause", found.note.?);
        try std.testing.expectEqualStrings("b = 2", found.quote.?);
        try std.testing.expectEqualStrings("alice@example.test", found.author.?);
        const issue = try forge.findIssue(workspace, &arena, core, id[0..8]);
        try std.testing.expectEqual(@as(u64, 2), issue.anchor.?.line);
    }

    // the excerpt and the file markers the web ui shows
    {
        var repo = try GitRepo.open(io, allocator, .{ .path = core.path });
        defer repo.deinit(io, allocator);
        const markers = try anchor.fileAnchors(.git, .{}, &repo, io, &arena, "src");
        try std.testing.expectEqual(1, markers.len);
        try std.testing.expectEqual(@as(u64, 2), markers[0].line);
        const ex = (try anchor.excerpt(.git, .{}, &repo, io, &arena, .{ .file = "src/a.zig", .line = 2, .line_text = "const b = 2;", .commit = &head })).?;
        try std.testing.expect(ex.at_filed_commit);
        try std.testing.expectEqual(@as(u64, 1), ex.first);
        try std.testing.expectEqual(3, ex.lines.len);
        // without a commit, the head's copy, with the line found where it moved
        const moved = (try anchor.excerpt(.git, .{}, &repo, io, &arena, .{ .file = "src/a.zig", .line = 1, .line_text = "fn main() void {}" })).?;
        try std.testing.expectEqual(@as(u64, 3), moved.line);
        try std.testing.expect(!moved.changed);
    }

    // close with a comment, then the comments read back
    try forge.commentIssue(workspace, core, &id, "fixed", .closed);
    try std.testing.expectEqual(1, (try report.list(workspace, &arena, false)).len);
    try std.testing.expectEqual(2, (try report.list(workspace, &arena, true)).len);
    const comments = try forge.comments(workspace, &arena, core, &id);
    try std.testing.expectEqual(1, comments.len);
    try std.testing.expectEqualStrings("fixed", comments[0].body);
    try forge.setIssueStatus(workspace, core, &id, .open);
    try std.testing.expectEqual(2, (try report.list(workspace, &arena, false)).len);

    // a given id and time (a migration): once, then refused
    const given = "00112233445566778899aabbccddeeff".*;
    _ = try forge.fileIssueWith(workspace, core, .{ .title = "migrated", .labels = "report radar", .status = .closed, .id = given, .timestamp = 1893456000, .anchor = .{ .file = "src/a.zig", .line = 1, .line_text = "const a = 1;" } });
    try std.testing.expectError(error.IssueExists, forge.fileIssueWith(workspace, core, .{ .title = "migrated", .id = given }));
    const migrated = try report.find(workspace, &arena, "001122");
    try std.testing.expectEqualStrings("closed", migrated.status);
    try std.testing.expectEqual(@as(u64, 1893456000), migrated.created_timestamp);
}
