// the CI routes of the integration, under /ci (ci/web.zig hands them over):
//
//   POST /ci/run/patch   form: repo, id, back    "Run CI" on a patch page
//   POST /ci/run/stack   form: id, back          "Run CI" on a stack page
//   POST /ci/api/patch   {"repo","id","requested_by"?}  -> {subject, checkout, jobs}
//   POST /ci/api/stack   {"id","requested_by"?}         -> {subject, checkout, jobs}
//   GET  /ci/api/stack/<id>   -> {subject, ci, gate}    the stack's CI and merge gate
//
// The form routes redirect back with a flash message, like cpull's own forms.
const std = @import("std");
const db = @import("../ci/db.zig");
const ci_app = @import("../ci/app.zig");
const integrate = @import("integrate.zig");
const patchci = @import("patchci.zig");
const status = @import("status.zig");
const gate = @import("gate.zig");

const App = ci_app.App;
const Request = std.http.Server.Request;

pub fn handles(method: std.http.Method, path: []const u8) bool {
    if (method == .POST) return std.mem.eql(u8, path, "/run/patch") or std.mem.eql(u8, path, "/run/stack") or
        std.mem.eql(u8, path, "/api/patch") or std.mem.eql(u8, path, "/api/stack");
    return std.mem.startsWith(u8, path, "/api/stack/");
}

pub fn handle(app: *App, a: std.mem.Allocator, request: *Request, path: []const u8) !void {
    const ws = integrate.workspace orelse return fail(a, request, .not_found, "not a workspace server");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    if (request.head.method != .POST) {
        const id = path["/api/stack/".len..];
        const aa = arena.allocator();
        const members = patchci.stackMembers(ws, &arena, id) catch |e| return fail(a, request, .not_found, @errorName(e));
        const found = @import("../workspace.zig").readStack(ws, &arena, id) catch |e| return fail(a, request, .not_found, @errorName(e));
        const subject = try patchci.stackSubject(aa, &found.id);
        const summary = try status.forSubject(aa, app.store, subject, try patchci.tips(aa, members));
        const v = gate.verdict(ws, &arena, &found.id) catch |e| gate.Verdict{ .required = false, .ok = false, .reason = @errorName(e) };
        return json(a, request, .ok, .{ .subject = subject, .ci = summary, .gate = v });
    }

    var buf: [1024]u8 = undefined;
    const body = try request.readerExpectNone(&buf).allocRemaining(a, .limited(1 << 20));
    const form = std.mem.startsWith(u8, path, "/run/");
    var msg: []const u8 = "";
    var by: db.RequestedBy = if (form) .web else .cli;
    var repo: []const u8 = "";
    var id: []const u8 = "";
    var back: []const u8 = "/";
    if (form) {
        repo = field(a, body, "repo") orelse "";
        id = field(a, body, "id") orelse "";
        back = field(a, body, "back") orelse "/";
        if (back.len == 0 or back[0] != '/' or std.mem.startsWith(u8, back, "//")) back = "/";
    } else {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return fail(a, request, .bad_request, "invalid json");
        if (v != .object) return fail(a, request, .bad_request, "invalid json");
        if (v.object.get("repo")) |x| if (x == .string) {
            repo = x.string;
        };
        if (v.object.get("id")) |x| if (x == .string) {
            id = x.string;
        };
        if (v.object.get("requested_by")) |x| if (x == .string) {
            by = db.RequestedBy.parse(x.string) orelse by;
        };
    }
    const stack = std.mem.endsWith(u8, path, "/stack");
    const queued = (if (stack)
        patchci.queueStack(app, ws, &arena, id, by, &msg)
    else
        patchci.queuePatch(app, ws, &arena, repo, id, by, &msg)) catch |e| {
        const text = if (msg.len > 0) msg else @errorName(e);
        if (form) return flashBack(a, request, back, try std.fmt.allocPrint(a, "CI not queued: {s}", .{text}));
        return fail(a, request, .bad_request, text);
    };
    if (form) {
        var fresh: usize = 0;
        for (queued.jobs) |j| if (!j.deduplicated) {
            fresh += 1;
        };
        return flashBack(a, request, back, try std.fmt.allocPrint(a, "Queued {d} CI job{s} for this {s}{s}; see /ci for the queue.", .{
            fresh, if (fresh == 1) "" else "s", if (stack) "stack" else "patch", if (fresh < queued.jobs.len) " (the rest were already queued)" else "",
        }));
    }
    return json(a, request, .ok, queued);
}

fn field(a: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!std.mem.eql(u8, kv[0..eq], key)) continue;
        const v = a.dupe(u8, kv[eq + 1 ..]) catch return null;
        for (v) |*c| if (c.* == '+') {
            c.* = ' ';
        };
        return std.Uri.percentDecodeInPlace(v);
    }
    return null;
}

fn json(a: std.mem.Allocator, request: *Request, code: std.http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(a, value, .{});
    try request.respond(body, .{ .status = code, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn fail(a: std.mem.Allocator, request: *Request, code: std.http.Status, msg: []const u8) !void {
    try json(a, request, code, .{ .@"error" = msg });
}

// back to the page, with cpull's workspace flash (web.zig's cpull_local_flash cookie)
fn flashBack(a: std.mem.Allocator, request: *Request, back: []const u8, text: []const u8) !void {
    var encoded: std.Io.Writer.Allocating = .init(a);
    try std.Uri.Component.percentEncode(&encoded.writer, text, struct {
        fn isUnreserved(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        }
    }.isUnreserved);
    const cookie = try std.fmt.allocPrint(a, "cpull_local_flash=workspace:{s}; Path=/; HttpOnly; SameSite=Strict", .{encoded.written()});
    try request.respond("", .{ .status = .see_other, .extra_headers = &.{
        .{ .name = "location", .value = back },
        .{ .name = "set-cookie", .value = cookie },
    } });
}
