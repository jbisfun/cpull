// idlci's CI status summaries (its /api/status routes) as cpull's pages show
// them: one Jenkins ball, a label and a link per repo, commit, patch or
// stack, with the jobs behind it. idlci builds them (theme
// docs/workspace-tools.md §5); cpull only parses them and makes their links
// absolute, since an idlci href is a path on idlci's own server.
const std = @import("std");
const idlci = @import("idlci.zig");

const Allocator = std.mem.Allocator;

pub const JobRef = struct {
    id: i64,
    // "build fossify-ios/calculator-ios [App]"
    label: []const u8 = "",
    status: []const u8 = "",
    ball: []const u8 = "none",
    href: []const u8 = "",
    // local time it was queued
    when: []const u8 = "",
    head: []const u8 = "",
};

pub const Summary = struct {
    // passed, failed, running, warning or none (theme .ball-<x>)
    ball: []const u8 = "none",
    label: []const u8 = "",
    href: []const u8 = "",
    jobs: []const JobRef = &.{},
    // every job passed
    green: bool = false,
    // a subject's jobs ran on older commits than its branches hold now
    stale: bool = false,
};

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

// a Summary|null from idlci, its links made absolute on `c`'s server
pub fn parseSummary(c: *const idlci.Client, v: std.json.Value) ?Summary {
    if (v == .null) return null;
    var s = std.json.parseFromValueLeaky(Summary, c.a, v, parse_options) catch return null;
    absolute(c, &s);
    return s;
}

pub fn absolute(c: *const idlci.Client, s: *Summary) void {
    s.href = c.url(s.href);
    const jobs = c.a.dupe(JobRef, s.jobs) catch return;
    for (jobs) |*j| j.href = c.url(j.href);
    s.jobs = jobs;
}

// a job from idlci's Job JSON (the fields cpull reads) as a JobRef, for a
// job idlci only gave as a Job (an issue's linked jobs)
pub fn jobRefOfJob(c: *const idlci.Client, v: std.json.Value) ?JobRef {
    if (v != .object) return null;
    const o = v.object;
    const id = switch (o.get("id") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    var label: std.Io.Writer.Allocating = .init(c.a);
    label.writer.print("{s} {s}", .{ str(o, "command"), str(o, "project") }) catch {};
    if (o.get("targets")) |t| if (t == .array and t.array.items.len > 0) {
        label.writer.writeAll(" [") catch {};
        for (t.array.items, 0..) |x, i| if (x == .string) {
            if (i > 0) label.writer.writeByte(' ') catch {};
            label.writer.writeAll(x.string) catch {};
        };
        label.writer.writeByte(']') catch {};
    };
    const status = str(o, "status");
    return .{
        .id = id,
        .label = label.written(),
        .status = status,
        .ball = ballOf(status),
        .href = c.url(std.fmt.allocPrint(c.a, "/jobs/{d}", .{id}) catch ""),
        .head = str(o, "head"),
    };
}

pub fn str(o: std.json.ObjectMap, k: []const u8) []const u8 {
    const x = o.get(k) orelse return "";
    return if (x == .string) x.string else "";
}

pub fn ballOf(status: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "queued", "running" }, .{ "running", "running" }, .{ "passed", "passed" }, .{ "failed", "failed" },
    };
    for (map) |e| if (std.mem.eql(u8, e[0], status)) return e[1];
    return "none";
}

// the jobs that ran on each commit of a repo: short oid -> summary
pub const CommitIndex = struct {
    map: std.StringHashMapUnmanaged(Summary) = .empty,

    pub fn get(self: CommitIndex, oid: []const u8) ?Summary {
        return self.map.get(oid[0..@min(oid.len, 7)]);
    }
};

// idlci's {"<oid[0..7]>": Summary} as an index
pub fn parseCommitIndex(c: *const idlci.Client, v: std.json.Value) CommitIndex {
    var index: CommitIndex = .{};
    if (v != .object) return index;
    var it = v.object.iterator();
    while (it.next()) |e| {
        const s = parseSummary(c, e.value_ptr.*) orelse continue;
        index.map.put(c.a, e.key_ptr.*, s) catch {};
    }
    return index;
}

test parseSummary {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: idlci.Client = .{ .a = a, .http = undefined, .base = "http://127.0.0.1:8737" };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"ball":"failed","label":"CI failed: test p","href":"/projects/p","green":false,"stale":false,"extra":1,
        \\ "jobs":[{"id":2,"label":"test p","status":"failed","ball":"failed","href":"/jobs/2","when":"12:00","head":"abc1234"}]}
    , .{});
    const s = parseSummary(&c, v).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:8737/projects/p", s.href);
    try std.testing.expectEqualStrings("http://127.0.0.1:8737/jobs/2", s.jobs[0].href);
    try std.testing.expect(!s.green);
    try std.testing.expect(parseSummary(&c, .null) == null);
    const job = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":7,"project":"app","command":"build","targets":["App"],"status":"queued","head":"abc"}
    , .{});
    const ref = jobRefOfJob(&c, job).?;
    try std.testing.expectEqualStrings("build app [App]", ref.label);
    try std.testing.expectEqualStrings("running", ref.ball);
}
