const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const ws = @import("../workspace.zig");

const GitRepo = rp.Repo(.git, .{});
const ident = "alice <alice@example.test>";

const pullfile_text =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\<key>repos</key>
    \\<array>
    \\<dict><key>name</key><string>core</string><key>branch</key><string>master</string></dict>
    \\<dict><key>name</key><string>group/app</string><key>branch</key><string>master</string></dict>
    \\<dict><key>name</key><string>idle</string><key>branch</key><string>master</string></dict>
    \\</array>
    \\</dict>
    \\</plist>
;

// a repo at `path` with a base commit on master, a `feature` branch one
// commit ahead touching `file`, and master checked out unless `on_feature`
fn initRepo(io: std.Io, allocator: std.mem.Allocator, path: []const u8, file: []const u8) !void {
    var repo = try GitRepo.init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    {
        const f = try repo.core.work_dir.createFile(io, "base.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "base\n");
    }
    try repo.add(io, allocator, &.{"base.txt"});
    _ = try repo.commit(io, allocator, .{ .message = "base", .author = ident, .committer = ident });
    try repo.addBranch(io, .{ .name = "feature" });
    {
        var switched = try repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "feature" } } });
        switched.deinit();
    }
    {
        const f = try repo.core.work_dir.createFile(io, file, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "feature\n");
    }
    try repo.add(io, allocator, &.{file});
    _ = try repo.commit(io, allocator, .{ .message = "feature", .author = ident, .committer = ident });
}

test "workspace urls" {
    try std.testing.expect(ui.RoutablePage.fromUrlWorkspace("/").? == .workspace);
    try std.testing.expectEqual(.stacks, ui.RoutablePage.fromUrlWorkspace("/home/stacks").?.workspace.view);
    const stack = ui.RoutablePage.fromUrlWorkspace("/home/stacks/00112233445566778899aabbccddeeff").?;
    try std.testing.expectEqual(.stack, stack.workspace.view);
    try std.testing.expectEqual(null, ui.RoutablePage.fromUrlWorkspace("/home/stacks/xyz"));
    try std.testing.expectEqual(null, ui.RoutablePage.fromUrlWorkspace("/home/users"));
    // repo pages carry the repo identity, nested names joined by "."
    try std.testing.expectEqual(.repo, ui.RoutablePage.fromUrlWorkspace("/ws:group.app/issues").?.parent());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("group.app", try ws.keyOf(arena.allocator(), "group/app"));
    try std.testing.expectEqualStrings("/home/stacks/00112233445566778899aabbccddeeff", try stack.toUrl(&arena));
}

test "workspace stack lifecycle" {
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
    // a global config with an identity, so no test reads the user's
    const config_path = try std.Io.Dir.path.join(aa, &.{ root, "gitconfig" });
    {
        const f = try temp.dir.createFile(io, "gitconfig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "[user]\n\tname = alice\n\temail = alice@example.test\n");
    }
    {
        var root_repo = try GitRepo.init(io, allocator, .{ .path = root });
        root_repo.deinit(io, allocator);
    }
    try temp.dir.createDirPath(io, "group");
    try initRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ root, "core" }), "core.txt");
    try initRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ root, "group", "app" }), "app.txt");
    try initRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ root, "idle" }), "idle.txt");

    // detection: the workspace, unless a nested repo is nearer
    try std.testing.expectEqualStrings(root, (try ws.detect(io, aa, root, root)).?);
    try std.testing.expectEqual(null, try ws.detect(io, aa, root, try std.Io.Dir.path.join(aa, &.{ root, "core" })));

    const workspace = try ws.Workspace.load(io, allocator, aa, root, config_path);
    try std.testing.expectEqual(3, workspace.repos.len);
    try std.testing.expectEqualStrings(ws.root_key, workspace.events.?.key);
    try std.testing.expectEqualStrings("group.app", workspace.byIdentity(try aa.print("{s}:group.app", .{workspace.name})).?.key);

    // feature is checked out, so master (the target) can move
    const created = try ws.createStack(workspace, aa, "land the api", "", "api", &.{
        .{ .repo = "core", .source_branch = "feature" },
        .{ .repo = "group/app", .source_branch = "feature" },
    });
    try std.testing.expectEqual(2, created.members.len);
    try std.testing.expectError(error.RepoNotFound, ws.createStack(workspace, aa, "x", "", "", &.{.{ .repo = "nope", .source_branch = "feature" }}));

    const detail = try ws.stackDetail(workspace, &arena, created.id[0..6], null);
    try std.testing.expectEqualStrings("open", detail.status);
    try std.testing.expect(detail.mergeable);
    try std.testing.expectEqualStrings("fast_forward", detail.members[0].mergeable);
    try std.testing.expectEqualStrings("group/app", detail.members[1].repo);

    // the pages list the repos (nested ones grouped), the patches and the stack
    {
        const home = try ws.buildPage(workspace, &arena, .{});
        try std.testing.expectEqual(3, home.repos.len);
        try std.testing.expectEqualStrings("group", home.repos[1].group.?);
        try std.testing.expectEqual(1, home.repos[0].open_patches);
        const text = try ui.Workspace.render(aa, home);
        try std.testing.expect(std.mem.indexOf(u8, text, "## group/") != null);
        const patches = try ws.buildPage(workspace, &arena, .{ .view = .patches });
        try std.testing.expectEqual(2, patches.patches.len);
        const stacks = try ws.buildPage(workspace, &arena, .{ .view = .stacks });
        try std.testing.expectEqual(1, stacks.stacks.len);
        try std.testing.expectEqual(2, stacks.stacks[0].members);
    }

    // merging moves both targets and records the pins
    const pins = try ws.mergeStack(workspace, &arena, &created.id);
    try std.testing.expectEqual(2, pins.len);
    for (pins, [_][]const u8{ "core", "group/app" }) |pin, name| {
        try std.testing.expectEqualStrings(name, pin.repo);
        var repo = try GitRepo.open(io, allocator, .{ .path = try std.Io.Dir.path.join(aa, &.{ root, name }) });
        defer repo.deinit(io, allocator);
        const master = (try repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        const feature = (try repo.readRef(io, .{ .kind = .head, .name = "feature" })).?;
        try std.testing.expectEqualStrings(&feature, &master);
        try std.testing.expectEqualStrings(&master, pin.oid);
    }
    const merged = try ws.stackDetail(workspace, &arena, &created.id, null);
    try std.testing.expectEqualStrings("merged", merged.status);
    try std.testing.expectEqualStrings("merged", merged.members[0].status);
    try std.testing.expectEqualStrings(pins[1].oid, merged.members[1].target_oid.?);
    // merging again changes nothing and reports the same pins
    try std.testing.expectEqualStrings(pins[0].oid, (try ws.mergeStack(workspace, &arena, &created.id))[0].oid);
}

test "a stack is all or nothing" {
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
    {
        var root_repo = try GitRepo.init(io, allocator, .{ .path = root });
        root_repo.deinit(io, allocator);
    }
    try temp.dir.createDirPath(io, "group");
    try initRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ root, "core" }), "core.txt");
    try initRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ root, "group", "app" }), "app.txt");
    const workspace = try ws.Workspace.load(io, allocator, aa, root, null);
    const created = try ws.createStack(workspace, aa, "two", "", "", &.{
        .{ .repo = "core", .source_branch = "feature" },
        .{ .repo = "group/app", .source_branch = "feature" },
    });

    // app checks out its target, so neither member merges
    const app_path = try std.Io.Dir.path.join(aa, &.{ root, "group", "app" });
    {
        var repo = try GitRepo.open(io, allocator, .{ .path = app_path });
        defer repo.deinit(io, allocator);
        var switched = try repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
        switched.deinit();
    }
    try std.testing.expectError(error.TargetBranchCheckedOut, ws.mergeStack(workspace, &arena, &created.id));
    const detail = try ws.stackDetail(workspace, &arena, &created.id, null);
    try std.testing.expect(!detail.mergeable);
    try std.testing.expectEqualStrings("checked_out", detail.members[1].mergeable);
    {
        var repo = try GitRepo.open(io, allocator, .{ .path = try std.Io.Dir.path.join(aa, &.{ root, "core" }) });
        defer repo.deinit(io, allocator);
        const master = (try repo.readRef(io, .{ .kind = .head, .name = "master" })).?;
        const feature = (try repo.readRef(io, .{ .kind = .head, .name = "feature" })).?;
        try std.testing.expect(!std.mem.eql(u8, &master, &feature));
    }
    try std.testing.expectEqualStrings("open", detail.status);
}
