// failed CI -> issue: when a workspace job (not a patch or stack job) fails
// on a repo checked out on its pullfile branch, cpull files one issue
// labelled `ci` in that repo for the failing target (project, command,
// targets, configuration), with the job's link and the end of its log. A
// later failure of the same target comments on that issue (reopening it if it
// was closed); the next pass comments and closes it. The pullfile's
// `cpull.ci_issues = false` turns this off.
//
// The jobs come from idlci's feed (`GET /api/feed?cursor=C&wait=S`, theme
// docs/workspace-tools.md §5): the workspace server long-polls it on a thread
// of its own and keeps the cursor, the issue each target maps to
// (`ci_issues`) and the jobs reported on each issue (`issue_jobs`, which the
// issue page lists) in .pull/cpull/integrate.json (state.zig).
const std = @import("std");
const evt = @import("../event.zig");
const ws_mod = @import("../workspace.zig");
const forge = @import("../forge.zig");
const tools = @import("tools.zig");
const idlci = @import("idlci.zig");
const state_mod = @import("state.zig");
const status = @import("status.zig");

const Workspace = ws_mod.Workspace;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.integrate);

pub const label = "ci";
const feed_limit = 50;

pub fn start(ws: *Workspace, wait_s: u64) void {
    const t = std.Thread.spawn(.{}, run, .{ ws, wait_s }) catch |e| {
        log.err("can't start the CI feed poller: {t}", .{e});
        return;
    };
    t.detach();
}

fn run(ws: *Workspace, wait_s: u64) void {
    var announced_down = false;
    while (!tools.stopped()) {
        const got = pollOnce(ws, wait_s) catch |e| blk: {
            log.warn("ci feed: {t}", .{e});
            break :blk false;
        };
        if (!got) {
            if (!announced_down) log.info("ci feed: idlci isn't running; polling for it", .{});
            announced_down = true;
            ws.io.sleep(.fromSeconds(10), .awake) catch {};
        } else announced_down = false;
    }
}

// one feed request and the jobs it brings; false when idlci isn't running
pub fn pollOnce(ws: *const Workspace, wait_s: u64) !bool {
    var arena = std.heap.ArenaAllocator.init(ws.gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var client = tools.connectIdlci(ws.io, aa, ws.root) orelse return false;
    defer client.deinit();
    const saved = try state_mod.load(ws.io, aa, ws.root);
    const path = if (saved.ci_cursor) |c|
        try std.fmt.allocPrint(aa, "/api/feed?cursor={s}&wait={d}&limit={d}", .{ try idlci.queryEscape(aa, c), @min(wait_s, 60), feed_limit })
    else
        // the first call only learns where the feed is now
        "/api/feed";
    const feed = try client.get(path);
    if (feed != .object) return error.BadFeed;
    const cursor = feed.object.get("cursor") orelse return error.BadFeed;
    if (feed.object.get("jobs")) |jobs| if (jobs == .array and saved.ci_cursor != null) for (jobs.array.items) |job| {
        handle(ws, &client, &arena, job) catch |e| log.warn("ci issue for job {f}: {t}", .{ std.json.fmt(job.object.get("id") orelse .null, .{}), e });
    };
    if (cursor == .string) try state_mod.update(ws.io, ws.gpa, ws.root, struct {
        fn f(a: Allocator, s: *state_mod.State, c: []const u8) !bool {
            if (s.ci_cursor) |old| if (std.mem.eql(u8, old, c)) return false;
            s.ci_cursor = try a.dupe(u8, c);
            return true;
        }
    }.f, cursor.string);
    return true;
}

// one finished job of the feed (idlci's FeedJob: Job + {idl, log_tail})
pub fn handle(ws: *const Workspace, client: *const idlci.Client, arena: *std.heap.ArenaAllocator, job: std.json.Value) !void {
    const aa = arena.allocator();
    if (job != .object) return;
    const o = job.object;
    if (o.get("subject")) |s| if (s != .null) return;
    const job_status = status.str(o, "status");
    const failed = std.mem.eql(u8, job_status, "failed");
    if (!failed and !std.mem.eql(u8, job_status, "passed")) return;
    if (!tools.config(ws.io, ws.gpa, ws.root).ci_issues) return;
    const id = switch (o.get("id") orelse return) {
        .integer => |n| n,
        else => return,
    };
    const repo = ws.byName(status.str(o, "repo")) orelse return;
    // the default branch: the pullfile's branch for the repo
    const branch = status.str(o, "branch");
    if (branch.len == 0 or !std.mem.eql(u8, branch, repo.branch)) return;

    const key = try keyOf(aa, o);
    const saved = try state_mod.load(ws.io, aa, ws.root);
    const tracked = saved.ci_issues.map.get(key);
    const issue: ?forge.IssueInfo = if (tracked) |t|
        (if (std.mem.eql(u8, t.repo, repo.name)) try forge.readIssue(ws, arena, repo, t.issue) else null)
    else
        null;

    const what = try describe(aa, o);
    const head = status.str(o, "head");
    const where = try std.fmt.allocPrint(aa, "`{s}@{s}`", .{ branch, if (head.len > 0) head else "?" });
    const job_url = client.url(try std.fmt.allocPrint(aa, "/jobs/{d}", .{id}));
    if (failed) {
        const tail = try tailBlock(aa, status.str(o, "log_tail"));
        if (issue) |i| {
            const body = try std.fmt.allocPrint(aa, "{s} failed again in [job #{d}]({s}) on {s}.\n\n{s}", .{ what, id, job_url, where, tail });
            try forge.commentIssue(ws, repo, i.id, body, if (i.status == .closed) .open else null);
            try linkJob(ws, repo.name, i.id, id);
            log.info("job #{d} failed: commented on ci issue {s} in {s}", .{ id, i.id[0..8], repo.name });
        } else {
            const title = try std.fmt.allocPrint(aa, "CI: {s} fails", .{what});
            const description = try std.fmt.allocPrint(aa, "{s} failed in [job #{d}]({s}) on {s}.\n\n{s}\n\ncpull filed this issue because the job failed on the repo's pullfile branch, and closes it when the same job passes again (pullfile `cpull.ci_issues` turns this off).", .{ what, id, job_url, where, tail });
            const new_id = try forge.fileIssue(ws, repo, std.mem.trim(u8, title[0..@min(title.len, 200)], " "), description, label);
            try state_mod.update(ws.io, ws.gpa, ws.root, struct {
                fn f(a: Allocator, s: *state_mod.State, args: anytype) !bool {
                    try s.ci_issues.map.put(a, args.key, .{ .repo = args.repo, .issue = args.issue });
                    return true;
                }
            }.f, .{ .key = key, .repo = repo.name, .issue = @as([]const u8, &new_id) });
            try linkJob(ws, repo.name, &new_id, id);
            log.info("job #{d} failed: filed ci issue {s} in {s}", .{ id, new_id[0..8], repo.name });
        }
    } else if (issue) |i| if (i.status == .open) {
        const body = try std.fmt.allocPrint(aa, "{s} passes again in [job #{d}]({s}) on {s}; closing.", .{ what, id, job_url, where });
        try forge.commentIssue(ws, repo, i.id, body, .closed);
        try linkJob(ws, repo.name, i.id, id);
        log.info("job #{d} passed: closed ci issue {s} in {s}", .{ id, i.id[0..8], repo.name });
    };
}

// record that job `job` was reported on an issue, for the issue page
fn linkJob(ws: *const Workspace, repo: []const u8, issue: []const u8, job: i64) !void {
    try state_mod.update(ws.io, ws.gpa, ws.root, struct {
        fn f(a: Allocator, s: *state_mod.State, args: anytype) !bool {
            const key = try state_mod.issueJobsKey(a, args.repo, args.issue);
            const gop = try s.issue_jobs.map.getOrPut(a, key);
            const old: []const i64 = if (gop.found_existing) gop.value_ptr.* else &.{};
            for (old) |j| if (j == args.job) return false;
            gop.value_ptr.* = try std.mem.concat(a, i64, &.{ old, &.{args.job} });
            return true;
        }
    }.f, .{ .repo = repo, .issue = issue, .job = job });
}

// what identifies "the same job" across runs: project|command|targets|configuration|strict
pub fn keyOf(a: Allocator, o: std.json.ObjectMap) ![]const u8 {
    var targets: std.ArrayList([]const u8) = .empty;
    if (o.get("targets")) |t| if (t == .array) for (t.array.items) |x| if (x == .string) try targets.append(a, x.string);
    const strict = if (o.get("strict")) |s| s == .bool and s.bool else false;
    const configuration = status.str(o, "configuration");
    return std.fmt.allocPrint(a, "{s}|{s}|{s}|{s}|{}", .{ status.str(o, "project"), status.str(o, "command"), try std.mem.join(a, " ", targets.items), if (configuration.len > 0) configuration else "none", strict });
}

// "`idl build -c release` in fossify-ios/calculator-ios (App)"
pub fn describe(a: Allocator, o: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const idl = status.str(o, "idl");
    try out.writer.print("`{s}` in {s}", .{ if (idl.len > 0) idl else try std.fmt.allocPrint(a, "idl {s}", .{status.str(o, "command")}), status.str(o, "project") });
    var targets: std.ArrayList([]const u8) = .empty;
    if (o.get("targets")) |t| if (t == .array) for (t.array.items) |x| if (x == .string) try targets.append(a, x.string);
    if (targets.items.len > 0) try out.writer.print(" ({s})", .{try std.mem.join(a, ", ", targets.items)});
    return out.written();
}

// the end of the job's log (idlci's log_tail) as a fenced block
fn tailBlock(a: Allocator, tail: []const u8) ![]const u8 {
    if (tail.len == 0) return "(no log)";
    // a fence longer than any backtick run in the log
    var longest: usize = 0;
    var run_len: usize = 0;
    for (tail) |c| {
        run_len = if (c == '`') run_len + 1 else 0;
        longest = @max(longest, run_len);
    }
    const fence = try a.alloc(u8, @max(3, longest + 1));
    @memset(fence, '`');
    return std.fmt.allocPrint(a, "The end of its log:\n\n{s}\n{s}\n{s}", .{ fence, std.mem.trimEnd(u8, tail, " \r\n"), fence });
}

test keyOf {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":3,"project":"fossify-ios/calculator-ios","command":"build","targets":["App","Ext"],"configuration":"release","strict":false,"idl":"idl build -c release"}
    , .{});
    // the same key the in-process CI kept in ci.db (ciissue.keyOf of a db.Job)
    try std.testing.expectEqualStrings("fossify-ios/calculator-ios|build|App Ext|release|false", try keyOf(a, v.object));
    try std.testing.expectEqualStrings("`idl build -c release` in fossify-ios/calculator-ios (App, Ext)", try describe(a, v.object));
    try std.testing.expect(std.mem.indexOf(u8, try tailBlock(a, "a ``` b"), "````\na ``` b\n````") != null);
}
