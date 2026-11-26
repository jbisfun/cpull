// `cpull report`: line-anchored issues (src/report/) over a scratch pull workspace
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const ws = @import("../workspace.zig");
const report = @import("../report/report.zig");
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

test "cpull report files, lists, closes and migrates" {
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

    // filing reads the line and records the head commit, which holds it
    const filed = try report.add(workspace, &arena, .{ .repo = "core", .file = "./src/a.zig", .line = 2, .quote = " b = 2 ", .note = "b is wrong\nbecause" });
    try std.testing.expectEqualStrings("src/a.zig", filed.file);
    try std.testing.expectEqualStrings("const b = 2;", filed.line_text);
    try std.testing.expectEqualStrings("b = 2", filed.quote.?);
    try std.testing.expectEqualStrings("b is wrong", filed.title);
    try std.testing.expect(filed.commit != null);
    try std.testing.expectError(error.NoSuchLine, report.add(workspace, &arena, .{ .repo = "core", .file = "src/a.zig", .line = 4 }));
    try std.testing.expectError(error.OutsideRepo, report.add(workspace, &arena, .{ .repo = "core", .file = "../pullfile.plist", .line = 1 }));
    try std.testing.expectError(error.RepoNotFound, report.add(workspace, &arena, .{ .repo = "nope", .file = "a", .line = 1 }));
    // "." files into the events repo, here the workspace root
    _ = try report.add(workspace, &arena, .{ .repo = ".", .file = "pullfile.plist", .line = 1 });

    {
        const open = try report.list(workspace, &arena, false);
        try std.testing.expectEqual(2, open.len);
        const found = try report.find(workspace, &arena, filed.id[0..6]);
        try std.testing.expectEqualStrings("core", found.repo);
        try std.testing.expectEqualStrings("b is wrong\nbecause", found.note.?);
        try std.testing.expectEqualStrings("alice@example.test", found.author.?);
    }

    // the excerpt and the file markers the web ui shows
    {
        var repo = try GitRepo.open(io, allocator, .{ .path = try std.Io.Dir.path.join(aa, &.{ root, "core" }) });
        defer repo.deinit(io, allocator);
        const markers = try anchor.fileAnchors(.git, .{}, &repo, io, &arena, "src");
        try std.testing.expectEqual(1, markers.len);
        try std.testing.expectEqual(@as(u64, 2), markers[0].line);
        const ex = (try anchor.excerpt(.git, .{}, &repo, io, &arena, .{ .file = "src/a.zig", .line = 2, .line_text = "const b = 2;", .commit = filed.commit })).?;
        try std.testing.expect(ex.at_filed_commit);
        try std.testing.expectEqual(@as(u64, 1), ex.first);
        try std.testing.expectEqual(3, ex.lines.len);
        // without a commit, the head's copy, with the line found where it moved
        const moved = (try anchor.excerpt(.git, .{}, &repo, io, &arena, .{ .file = "src/a.zig", .line = 1, .line_text = "fn main() void {}" })).?;
        try std.testing.expectEqual(@as(u64, 3), moved.line);
        try std.testing.expect(!moved.changed);
    }

    _ = try report.setStatus(workspace, &arena, filed.id, .closed);
    try std.testing.expectEqual(1, (try report.list(workspace, &arena, false)).len);
    try std.testing.expectEqual(2, (try report.list(workspace, &arena, true)).len);

    // migrating radar's json: once, then skipped
    {
        const f = try temp.dir.createFile(io, "radar.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\[{"number":1,"repo":"core","file":"src/a.zig","line":1,"line_text":"const a = 1;","quote":null,"note":"a note","status":"open","source":"wiki","created":"2030-01-01T00:00:00Z"},
            \\ {"number":2,"repo":"core","file":"src/a.zig","line":3,"line_text":"fn main() void {}","quote":"main","note":null,"status":"closed","source":"cli","created":"2030-01-02T00:00:00.5Z"},
            \\ {"number":3,"repo":"gone","file":"x","line":1,"line_text":"","status":"open","created":"2030-01-02T00:00:00Z"}]
        );
    }
    const radar_path = try std.Io.Dir.path.join(aa, &.{ root, "radar.json" });
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();
    try report.run(io, allocator, root, .{ .action = .migrate, .args = &.{radar_path} }, config_path, &out.writer, &err.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "migrated 2 of 3 radar reports (1 open, 1 closed); 0 already present, 1 in unknown repos") != null);
    out.clearRetainingCapacity();
    try report.run(io, allocator, root, .{ .action = .migrate, .args = &.{radar_path} }, config_path, &out.writer, &err.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "migrated 0 of 3 radar reports (0 open, 0 closed); 2 already present") != null);

    const all = try report.list(workspace, &arena, true);
    try std.testing.expectEqual(4, all.len);
    var migrated: usize = 0;
    for (all) |r| if (std.mem.eql(u8, r.source, "wiki") or (std.mem.eql(u8, r.source, "cli") and r.quote != null and std.mem.eql(u8, r.quote.?, "main"))) {
        migrated += 1;
        // the radar filing time is kept, and the commit holding the line is found
        try std.testing.expect(r.created_timestamp >= 1893456000);
        try std.testing.expect(r.commit != null);
    };
    try std.testing.expectEqual(2, migrated);
}
