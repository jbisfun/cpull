// failed CI -> issue: when a workspace job (not a patch or stack job) fails
// on a repo checked out on its pullfile branch, cpull files one issue
// labelled `ci` in that repo for the failing target (project, command,
// targets, configuration), with the job's link and the end of its log. A
// later failure of the same target comments on that issue (reopening it if it
// was closed); the next pass comments and closes it. The pullfile's
// `cpull.ci_issues = false` turns this off. The issue a target maps to lives
// in the CI db (ci_issues), and every job reported on an issue is linked to it
// (issue_jobs), so the issue page lists them.
const std = @import("std");
const db = @import("../ci/db.zig");
const ci_app = @import("../ci/app.zig");
const evt = @import("../event.zig");
const ws_mod = @import("../workspace.zig");
const forge = @import("forge.zig");
const integrate = @import("integrate.zig");

const App = ci_app.App;
const Workspace = ws_mod.Workspace;
const log = std.log.scoped(.integrate);

pub const label = "ci";
const tail_lines = 30;
const tail_bytes = 6 * 1024;

// ci.Runner.Hook: called on the worker thread after each job
pub fn onFinish(ctx: *anyopaque, job_id: i64) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ws = integrate.workspace orelse return;
    handle(app, ws, job_id) catch |e| log.warn("ci issue for job #{d}: {t}", .{ job_id, e });
}

pub fn handle(app: *App, ws: *const Workspace, job_id: i64) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const job = (try app.store.get(aa, job_id)) orelse return;
    if (job.subject != null) return;
    if (job.status != .passed and job.status != .failed) return;
    if (!integrate.config(ws.io, ws.gpa, ws.root).ci_issues) return;
    const repo_name = job.git.repo orelse return;
    const repo = ws.byName(repo_name) orelse return;
    // the default branch: the pullfile's branch for the repo
    const branch = job.git.branch orelse return;
    if (!std.mem.eql(u8, branch, repo.branch)) return;

    const key = try keyOf(aa, job);
    const tracked = try app.store.ciIssue(aa, key);
    const issue: ?forge.IssueInfo = if (tracked) |t|
        (if (std.mem.eql(u8, t.repo, repo.name)) try forge.readIssue(ws, &arena, repo, t.issue) else null)
    else
        null;

    const what = try describe(aa, job);
    const where = try std.fmt.allocPrint(aa, "`{s}@{s}`", .{ branch, job.git.head orelse "?" });
    switch (job.status) {
        .failed => {
            const body = try std.fmt.allocPrint(aa, "{s} failed again in [job #{d}](/ci/jobs/{d}) on {s}.\n\n{s}", .{ what, job.id, job.id, where, try tailBlock(app, aa, job) });
            if (issue) |i| {
                try forge.commentIssue(ws, repo, i.id, body, if (i.status == .closed) .open else null);
                try app.store.linkIssueJob(repo.name, i.id, job.id);
                log.info("job #{d} failed: commented on ci issue {s} in {s}", .{ job.id, i.id[0..8], repo.name });
            } else {
                const title = try std.fmt.allocPrint(aa, "CI: {s} fails", .{what});
                const description = try std.fmt.allocPrint(aa, "{s} failed in [job #{d}](/ci/jobs/{d}) on {s}.\n\n{s}\n\ncpull filed this issue because the job failed on the repo's pullfile branch, and closes it when the same job passes again (pullfile `cpull.ci_issues` turns this off).", .{ what, job.id, job.id, where, try tailBlock(app, aa, job) });
                const id = try forge.fileIssue(ws, repo, std.mem.trim(u8, title[0..@min(title.len, 200)], " "), description, label);
                try app.store.setCiIssue(key, repo.name, &id);
                try app.store.linkIssueJob(repo.name, &id, job.id);
                log.info("job #{d} failed: filed ci issue {s} in {s}", .{ job.id, id[0..8], repo.name });
            }
        },
        .passed => if (issue) |i| if (i.status == .open) {
            const body = try std.fmt.allocPrint(aa, "{s} passes again in [job #{d}](/ci/jobs/{d}) on {s}; closing.", .{ what, job.id, job.id, where });
            try forge.commentIssue(ws, repo, i.id, body, .closed);
            try app.store.linkIssueJob(repo.name, i.id, job.id);
            log.info("job #{d} passed: closed ci issue {s} in {s}", .{ job.id, i.id[0..8], repo.name });
        },
        else => {},
    }
}

// what identifies "the same job" across runs
pub fn keyOf(a: std.mem.Allocator, j: db.Job) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}|{s}|{s}|{t}|{}", .{ j.project, j.command.name(), try std.mem.join(a, " ", j.targets), j.configuration, j.strict });
}

// "`idl build -c release` in fossify-ios/calculator-ios (App)"
pub fn describe(a: std.mem.Allocator, j: db.Job) ![]const u8 {
    const args = try j.command.idlArgs(a, j.configuration, j.strict, &.{});
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("`idl {s}` in {s}", .{ try std.mem.join(a, " ", args), j.project });
    if (j.targets.len > 0) try out.writer.print(" ({s})", .{try std.mem.join(a, ", ", j.targets)});
    return out.written();
}

// the end of the job's log as a fenced block
fn tailBlock(app: *App, a: std.mem.Allocator, j: db.Job) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(app.io, j.log, a, .limited(64 << 20)) catch return "(no log)";
    const t = tail(text, tail_lines, tail_bytes);
    // a fence longer than any backtick run in the log
    var longest: usize = 0;
    var run: usize = 0;
    for (t) |c| {
        run = if (c == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    const fence = try a.alloc(u8, @max(3, longest + 1));
    @memset(fence, '`');
    return std.fmt.allocPrint(a, "The end of its log:\n\n{s}\n{s}\n{s}", .{ fence, t, fence });
}

pub fn tail(text_in: []const u8, lines: usize, max: usize) []const u8 {
    const text = std.mem.trimEnd(u8, text_in, " \r\n");
    var start = text.len;
    var n: usize = 0;
    while (start > 0) {
        if (text[start - 1] == '\n') {
            n += 1;
            if (n == lines) break;
        }
        start -= 1;
    }
    if (text.len - start > max) start = text.len - max;
    // don't start mid utf-8 sequence
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    return text[start..];
}

test tail {
    try std.testing.expectEqualStrings("c\nd", tail("a\nb\nc\nd\n", 2, 100));
    try std.testing.expectEqualStrings("a\nb", tail("a\nb", 5, 100));
    try std.testing.expectEqualStrings("cd", tail("abcd", 5, 2));
}
