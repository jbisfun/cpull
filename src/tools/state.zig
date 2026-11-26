// cpull's own state for its integration with the other tools,
// `.pull/cpull/integrate.json` (theme docs/workspace-tools.md §4):
//
//   {"link_tips": {repo: oid},                  the `fixes #id` scanner's last tips
//    "ci_issues": {key: {repo, issue}},         the `ci` issue a failing target maps to
//    "issue_jobs": {"repo issue": [job ids]},   the idlci jobs reported on an issue
//    "ci_cursor": "..."}                        idlci's /api/feed cursor
//
// These lived in the CI's SQLite db while the CI ran inside cpull. When the
// file doesn't exist yet, they're read once from that db (.pull/cpull/ci/ci.db,
// else .pull/idlci/idlci.db) with the sqlite3 CLI, when it's installed.
// Every access loads and saves the whole file under one mutex; it is small.
const std = @import("std");
const discovery = @import("discovery");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.integrate);

pub const file_name = "integrate.json";

pub const CiIssue = struct { repo: []const u8, issue: []const u8 };

pub const State = struct {
    link_tips: std.json.ArrayHashMap([]const u8) = .{},
    ci_issues: std.json.ArrayHashMap(CiIssue) = .{},
    issue_jobs: std.json.ArrayHashMap([]const i64) = .{},
    ci_cursor: ?[]const u8 = null,
};

var mutex: std.Io.Mutex = .init;

pub fn path(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ try discovery.stateDir(a, root, .cpull), file_name });
}

// the state, with `f(state, args)` applied and saved when it returns true
pub fn update(io: std.Io, gpa: Allocator, root: []const u8, comptime f: anytype, args: anytype) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try loadLocked(io, a, root);
    if (try f(a, &state, args)) try saveLocked(io, a, root, state);
}

// a copy of the state in `a`
pub fn load(io: std.Io, a: Allocator, root: []const u8) !State {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return loadLocked(io, a, root);
}

fn loadLocked(io: std.Io, a: Allocator, root: []const u8) !State {
    const p = try path(a, root);
    const text = std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            const migrated = migrate(io, a, root);
            saveLocked(io, a, root, migrated) catch |x| log.warn("can't write {s}: {t}", .{ p, x });
            return migrated;
        },
        else => return e,
    };
    return std.json.parseFromSliceLeaky(State, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| {
        log.warn("{s} is unreadable ({t}); starting over", .{ p, e });
        return .{};
    };
}

fn saveLocked(io: std.Io, a: Allocator, root: []const u8, state: State) !void {
    const p = try path(a, root);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);
    const text = try std.json.Stringify.valueAlloc(a, state, .{ .whitespace = .indent_2 });
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{p});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), p, io);
}

pub fn issueJobsKey(a: Allocator, repo: []const u8, issue: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s}", .{ repo, issue });
}

// the tables of the old CI db, when there is one and sqlite3 can read it
fn migrate(io: std.Io, a: Allocator, root: []const u8) State {
    var state: State = .{};
    const candidates = [_][]const []const u8{ &.{ ".pull", "cpull", "ci", "ci.db" }, &.{ ".pull", "idlci", "idlci.db" } };
    for (candidates) |parts| {
        const db = std.fs.path.join(a, &.{ root, std.fs.path.join(a, parts) catch continue }) catch continue;
        _ = std.Io.Dir.cwd().statFile(io, db, .{}) catch continue;
        var got = false;
        if (query(io, a, db, "SELECT repo, oid FROM link_tips")) |rows| for (rows) |r| {
            const repo = field(r, "repo") orelse continue;
            const oid = field(r, "oid") orelse continue;
            state.link_tips.map.put(a, repo, oid) catch {};
            got = true;
        };
        if (query(io, a, db, "SELECT key, repo, issue FROM ci_issues")) |rows| for (rows) |r| {
            const key = field(r, "key") orelse continue;
            state.ci_issues.map.put(a, key, .{ .repo = field(r, "repo") orelse continue, .issue = field(r, "issue") orelse continue }) catch {};
            got = true;
        };
        if (query(io, a, db, "SELECT repo, issue, job FROM issue_jobs ORDER BY job")) |rows| for (rows) |r| {
            const key = issueJobsKey(a, field(r, "repo") orelse continue, field(r, "issue") orelse continue) catch continue;
            const job = switch (r.object.get("job") orelse continue) {
                .integer => |n| n,
                else => continue,
            };
            const gop = state.issue_jobs.map.getOrPut(a, key) catch continue;
            const old: []const i64 = if (gop.found_existing) gop.value_ptr.* else &.{};
            gop.value_ptr.* = std.mem.concat(a, i64, &.{ old, &.{job} }) catch old;
            got = true;
        };
        if (got) {
            log.info("took link tips, ci issues and issue jobs over from {s}", .{db});
            return state;
        }
    }
    return state;
}

fn field(row: std.json.Value, k: []const u8) ?[]const u8 {
    if (row != .object) return null;
    const v = row.object.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn query(io: std.Io, a: Allocator, db: []const u8, sql: []const u8) ?[]const std.json.Value {
    const r = std.process.run(a, io, .{ .argv = &.{ "sqlite3", "-readonly", "-json", db, sql }, .stdout_limit = .limited(64 << 20), .stderr_limit = .limited(1 << 20) }) catch return null;
    if (!r.term.success()) return null;
    const text = std.mem.trim(u8, r.stdout, " \r\n");
    if (text.len == 0) return &.{};
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return null;
    return if (v == .array) v.array.items else null;
}

test "state round trip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try update(io, std.testing.allocator, root, struct {
        fn f(aa: Allocator, s: *State, _: void) !bool {
            try s.link_tips.map.put(aa, "core", "abc");
            try s.ci_issues.map.put(aa, "p|build||none|false", .{ .repo = "core", .issue = "00ff" });
            try s.issue_jobs.map.put(aa, try issueJobsKey(aa, "core", "00ff"), &.{ 1, 2 });
            s.ci_cursor = "10.2";
            return true;
        }
    }.f, {});
    const s = try load(io, a, root);
    try std.testing.expectEqualStrings("abc", s.link_tips.map.get("core").?);
    try std.testing.expectEqualStrings("00ff", s.ci_issues.map.get("p|build||none|false").?.issue);
    try std.testing.expectEqual(@as(i64, 2), s.issue_jobs.map.get("core 00ff").?[1]);
    try std.testing.expectEqualStrings("10.2", s.ci_cursor.?);
}
