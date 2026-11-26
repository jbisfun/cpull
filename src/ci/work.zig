//! Work trees for patch and stack jobs: a pull-style workspace under
//! `.pull/cpull/ci/work/<subject>/` holding a linked git worktree of every repo
//! the job needs (the patch's repos at their source commits, the repos their
//! idl projects depend on at the workspace's current commits), at the same
//! paths as in the workspace, plus a copy of its pullfile. idl projects refer
//! to sibling repos by relative path (`../commons-ios`) and reject symlinks,
//! so the siblings are checked out too. Each subject keeps its tree between
//! jobs: it's moved to the new commits with `git checkout --detach --force`
//! and `git clean -fd`, which keeps ignored build output for incremental builds.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Prepared = struct {
    /// The work tree's root: run the project from `<root>/<project>`.
    root: []const u8,
    /// What was done, for the job's log.
    log: []const u8,
};

/// `.pull/cpull/ci/work/<subject with ':' as '-'>`.
pub fn dirFor(a: Allocator, root: []const u8, subject: []const u8) ![]const u8 {
    const key = try a.dupe(u8, subject);
    for (key) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '-' or c.* == '_' or c.* == '.')) {
        c.* = '-';
    };
    return std.fs.path.join(a, &.{ root, ".pull", "cpull", "ci", "work", key });
}

/// One `<repo> <oid>` line of a job's checkout.
pub const Line = struct { repo: []const u8, oid: []const u8 };

pub fn parseCheckout(a: Allocator, text: []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        try out.append(a, .{ .repo = line[0..sp], .oid = line[sp + 1 ..] });
    }
    return out.items;
}

/// The oid `checkout` records for `repo`.
pub fn oidOf(checkout: []const u8, repo: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, checkout, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..sp], repo)) return line[sp + 1 ..];
    }
    return null;
}

fn git(io: Io, a: Allocator, argv: []const []const u8) !void {
    const full = try std.mem.concat(a, []const u8, &.{ &.{"git"}, argv });
    const r = std.process.run(a, io, .{ .argv = full, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch return error.GitFailed;
    if (!r.term.success()) {
        std.log.scoped(.ci).warn("git {s}: {s}", .{ try std.mem.join(a, " ", argv), std.mem.trim(u8, r.stderr, " \r\n") });
        return error.GitFailed;
    }
}

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Check out `checkout` (see Line) in the subject's work tree.
pub fn prepare(io: Io, a: Allocator, root: []const u8, subject: []const u8, checkout: []const u8) !Prepared {
    const dir = try dirFor(a, root, subject);
    try Io.Dir.cwd().createDirPath(io, dir);
    var log: std.ArrayList(u8) = .empty;
    try log.print(a, "[idlci] work tree {s}\n", .{dir});
    for (try parseCheckout(a, checkout)) |line| {
        if (line.repo.len == 0 or std.mem.indexOf(u8, line.repo, "..") != null) return error.InvalidCheckout;
        const src = try std.fs.path.join(a, &.{ root, line.repo });
        const wt = try std.fs.path.join(a, &.{ dir, line.repo });
        const dot_git = try std.fs.path.join(a, &.{ wt, ".git" });
        var ok = false;
        if (exists(io, dot_git)) {
            if (git(io, a, &.{ "-C", wt, "checkout", "-q", "--detach", "--force", line.oid })) {
                git(io, a, &.{ "-C", wt, "clean", "-fdq" }) catch {};
                ok = true;
            } else |_| {
                // a broken tree (its repo moved, a stale lock): start over
                Io.Dir.cwd().deleteTree(io, wt) catch {};
                git(io, a, &.{ "-C", src, "worktree", "prune" }) catch {};
            }
        }
        if (!ok) {
            if (std.fs.path.dirname(wt)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
            if (exists(io, wt)) Io.Dir.cwd().deleteTree(io, wt) catch {};
            try git(io, a, &.{ "-C", src, "worktree", "add", "-q", "--detach", "--force", wt, line.oid });
        }
        try log.print(a, "[idlci]   {s} at {s}\n", .{ line.repo, line.oid[0..@min(line.oid.len, 10)] });
    }
    // a pull workspace: the root's pullfile, so idl and pull see the same repos
    const pf_src = try std.fs.path.join(a, &.{ root, "pullfile.plist" });
    if (Io.Dir.cwd().readFileAlloc(io, pf_src, a, .limited(16 << 20))) |data| {
        const pf_dst = try std.fs.path.join(a, &.{ dir, "pullfile.plist" });
        Io.Dir.cwd().writeFile(io, .{ .sub_path = pf_dst, .data = data }) catch {};
    } else |_| {}
    return .{ .root = dir, .log = log.items };
}

test parseCheckout {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try parseCheckout(arena.allocator(), "core abc\ngroup/app def\n");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("group/app", lines[1].repo);
    try std.testing.expectEqualStrings("def", oidOf("core abc\ngroup/app def", "group/app").?);
    try std.testing.expect(oidOf("core abc", "lib") == null);
    try std.testing.expect(std.mem.endsWith(u8, try dirFor(arena.allocator(), "/r", "patch:group/app:12"), "work/patch-group-app-12"));
}
