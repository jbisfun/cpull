// the workspace server's routes for the other tools, mounted through
// web.zig's `LocalHost.mounts` (main.zig):
//
//   POST /_ci/run/patch   form: repo, id, back    "Run CI" on a patch page
//   POST /_ci/run/stack   form: id, back          "Run CI" on a stack page
//   GET  /ci[/...]        -> idlci's page at the same path (it serves at /)
//   GET  /wiki/[...]      -> the wiki server's page at the same path
//
// The form routes ask idlci to run the members (runs.zig) and redirect back
// with a flash message, like cpull's own forms. The old /ci and /wiki/ urls
// (the CI and the wiki were served in-process before) redirect to the tool
// when it's running, and say it isn't otherwise.
const std = @import("std");
const discovery = @import("discovery");
const ws_mod = @import("../workspace.zig");
const runs = @import("runs.zig");

const Workspace = ws_mod.Workspace;
const Request = std.http.Server.Request;

pub const run_prefix = "/_ci";
pub const ci_prefix = "/ci";
pub const wiki_prefix = "/wiki";

// web.Mount.handle for /_ci
pub fn handleRun(ctx: *anyopaque, io: std.Io, request: *Request, gpa: std.mem.Allocator, target: []const u8) anyerror!void {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    _ = io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const stack = std.mem.eql(u8, path, "/_ci/run/stack");
    if (request.head.method != .POST or (!stack and !std.mem.eql(u8, path, "/_ci/run/patch")))
        return request.respond("not found\n", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
    if (!sameOrigin(request)) return request.respond("forbidden\n", .{ .status = .forbidden });
    var buf: [1024]u8 = undefined;
    const body = try request.readerExpectNone(&buf).allocRemaining(a, .limited(1 << 20));
    const repo = field(a, body, "repo") orelse "";
    const id = field(a, body, "id") orelse "";
    var back = field(a, body, "back") orelse "/";
    if (back.len == 0 or back[0] != '/' or std.mem.startsWith(u8, back, "//")) back = "/";
    var msg: []const u8 = "";
    const queued = (if (stack)
        runs.queueStack(ws, &arena, id, "web", &msg)
    else
        runs.queuePatch(ws, &arena, repo, id, "web", &msg)) catch |e| {
        return flashBack(a, request, back, try std.fmt.allocPrint(a, "CI not queued: {s}", .{if (msg.len > 0) msg else @errorName(e)}));
    };
    return flashBack(a, request, back, try std.fmt.allocPrint(a, "Queued {d} CI job{s} for this {s}{s}; idlci has the queue.", .{
        queued.fresh,                                                                    if (queued.fresh == 1) "" else "s", if (stack) "stack" else "patch",
        if (queued.fresh < queued.total) " (the rest were already queued)" else "",
    }));
}

// web.Mount.handle for /ci
pub fn handleCi(ctx: *anyopaque, io: std.Io, request: *Request, gpa: std.mem.Allocator, target: []const u8) anyerror!void {
    return redirect(@ptrCast(@alignCast(ctx)), io, request, gpa, target, .idlci, ci_prefix);
}

// web.Mount.handle for /wiki
pub fn handleWiki(ctx: *anyopaque, io: std.Io, request: *Request, gpa: std.mem.Allocator, target: []const u8) anyerror!void {
    return redirect(@ptrCast(@alignCast(ctx)), io, request, gpa, target, .wiki, wiki_prefix);
}

// the same page on the tool's own server: `/ci/jobs/4?x` -> `http://<idlci>/jobs/4?x`
fn redirect(ws: *Workspace, io: std.Io, request: *Request, gpa: std.mem.Allocator, target: []const u8, tool: discovery.Tool, prefix: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const addr = discovery.read(io, a, ws.root, tool) catch null orelse {
        const text = try std.fmt.allocPrint(a, "{s} isn't running (start it: pull launchctl start {s}). It used to be served here at {s}/; it is its own program now, with its own server.\n", .{ tool.label(), @tagName(tool), prefix });
        return request.respond(text, .{ .status = .service_unavailable, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
    };
    var rest = target[prefix.len..];
    if (rest.len == 0 or rest[0] == '?') rest = try std.mem.concat(a, u8, &.{ "/", rest });
    // idlci's old json api lived under /ci/api; it's at /api now
    const location = try std.fmt.allocPrint(a, "{s}{s}", .{ try discovery.baseUrl(a, addr), rest });
    return request.respond("", .{ .status = if (request.head.method == .GET or request.head.method == .HEAD) .found else .temporary_redirect, .extra_headers = &.{.{ .name = "location", .value = location }} });
}

// a write from this server's own pages (or not from a browser at all)
pub fn sameOrigin(request: *Request) bool {
    var it = request.iterateHeaders();
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
    }
    const o = origin orelse return true;
    const hst = host orelse return false;
    const after = if (std.mem.indexOf(u8, o, "://")) |i| o[i + 3 ..] else return false;
    return std.mem.eql(u8, after, hst);
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
