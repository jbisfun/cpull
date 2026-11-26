//! The CI end to end over HTTP: every page renders (idlci's pages_render test)
//! and the JSON API queues, lists, cancels and retries.
const std = @import("std");
const App = @import("app.zig").App;
const web = @import("web.zig");

const Io = std.Io;

fn serve(io: Io, server: *Io.net.Server, app: *App) void {
    while (true) {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var recv: [4096]u8 = undefined;
        var send: [4096]u8 = undefined;
        var br = stream.reader(io, &recv);
        var bw = stream.writer(io, &send);
        var http = std.http.Server.init(&br.interface, &bw.interface);
        while (http.reader.state == .ready) {
            var request = http.receiveHead() catch break;
            web.handle(app, io, &request, std.heap.smp_allocator, request.head.target) catch break;
        }
    }
}

const Fetched = struct { status: std.http.Status, body: []const u8 };

fn fetch(a: std.mem.Allocator, client: *std.http.Client, port: u16, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Fetched {
    var out: std.Io.Writer.Allocating = .init(a);
    const res = try client.fetch(.{
        .location = .{ .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, path }) },
        .method = method,
        .payload = payload,
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    return .{ .status = res.status, .body = out.written() };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    std.debug.print("missing {s} in:\n{s}\n", .{ needle, haystack[0..@min(haystack.len, 4000)] });
    return false;
}

test "pages render and the API answers" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "group/app-ios");
    try tmp.dir.writeFile(io, .{ .sub_path = "group/app-ios/idlproj.yml", .data = "name: App\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    var env = std.process.Environ.Map.init(a);
    try env.put("CPULL_IDL", "/bin/false");
    const app = try App.init(io, std.heap.smp_allocator, root, &env, .{ .jobs = 2, .watch = 15, .start_workers = false, .workspace_name = "ws" });

    var msg: []const u8 = "";
    const job = (try app.enqueue(a, .{ .project = "app-ios", .command = .build }, &msg)).job;
    try std.testing.expectEqualStrings("group/app-ios", job.project);
    _ = try app.store.claimNext(a);
    try app.store.finish(job.id, .failed, 1);
    _ = try app.enqueue(a, .{ .project = "app-ios", .command = .@"test" }, &msg);

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    const port = server.socket.address.getPort();
    (try std.Thread.spawn(.{}, serve, .{ io, &server, app })).detach();
    var client: std.http.Client = .{ .allocator = a, .io = io };

    const dash = try fetch(a, &client, port, .GET, "/ci", null);
    try std.testing.expectEqual(std.http.Status.ok, dash.status);
    try std.testing.expect(contains(dash.body, "group/app-ios"));
    try std.testing.expect(contains(dash.body, "Build Queue (1)"));
    try std.testing.expect(contains(dash.body, "w-cloud-lightning-rain"));
    try std.testing.expect(contains(dash.body, "watching"));
    try std.testing.expect(contains(dash.body, "href=\"/ci\" data-label=\"CI\" aria-current=\"page\""));

    const project = try fetch(a, &client, port, .GET, "/ci/projects/group/app-ios", null);
    try std.testing.expect(contains(project.body, "Build with Parameters"));
    try std.testing.expect(contains(project.body, "name: App"));
    try std.testing.expect(contains(project.body, "idl list failed"));
    try std.testing.expect(contains(project.body, "/ci/jobs?project=group%2Fapp-ios"));

    const jobs = try fetch(a, &client, port, .GET, "/ci/jobs", null);
    try std.testing.expect(contains(jobs.body, try std.fmt.allocPrint(a, "#{d}", .{job.id})));
    const failed = try fetch(a, &client, port, .GET, "/ci/jobs?status=failed&project=app-ios", null);
    try std.testing.expect(contains(failed.body, "Build History of app-ios"));

    const page = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/ci/jobs/{d}", .{job.id}), null);
    try std.testing.expect(contains(page.body, try std.fmt.allocPrint(a, "Build #{d}", .{job.id})));
    try std.testing.expect(contains(page.body, "Console Output"));

    const missing = try fetch(a, &client, port, .GET, "/ci/jobs/999", null);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
    try std.testing.expectEqualStrings("{\"error\":\"no job #999\"}", missing.body);

    const health = try fetch(a, &client, port, .GET, "/ci/api/health", null);
    try std.testing.expect(contains(health.body, root));

    const api = try fetch(a, &client, port, .GET, "/ci/api/projects", null);
    try std.testing.expect(contains(api.body, "\"path\":\"group/app-ios\",\"name\":\"app-ios\""));
    try std.testing.expect(contains(api.body, "\"last\":{\"build\":{"));

    const queued = try fetch(a, &client, port, .POST, "/ci/api/jobs", "{\"project\":\"app-ios\",\"command\":\"fmt-check\",\"requested_by\":\"web\"}");
    try std.testing.expectEqual(std.http.Status.ok, queued.status);
    try std.testing.expect(contains(queued.body, "\"command\":\"fmt-check\""));
    try std.testing.expect(contains(queued.body, "\"deduplicated\":false"));
    const again = try fetch(a, &client, port, .POST, "/ci/api/jobs", "{\"project\":\"app-ios\",\"command\":\"fmt-check\"}");
    try std.testing.expect(contains(again.body, "\"deduplicated\":true"));
    const bad = try fetch(a, &client, port, .POST, "/ci/api/jobs", "{\"project\":\"nope\",\"command\":\"build\"}");
    try std.testing.expectEqual(std.http.Status.bad_request, bad.status);
    try std.testing.expect(contains(bad.body, "unknown project"));

    const cancel = try fetch(a, &client, port, .POST, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/cancel", .{job.id + 2}), "null");
    try std.testing.expect(contains(cancel.body, "\"status\":\"cancelled\""));
    const retry = try fetch(a, &client, port, .POST, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/retry?by=mcp", .{job.id}), "null");
    try std.testing.expect(contains(retry.body, try std.fmt.allocPrint(a, "\"requested_by\":\"mcp\",\"retry_of\":{d}", .{job.id})));

    const log = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/log?tail=5", .{job.id}), null);
    try std.testing.expect(contains(log.body, "\"text\":\"\""));
    const search = try fetch(a, &client, port, .GET, "/ci/search?q=%23" ++ "1", null);
    try std.testing.expectEqual(std.http.Status.see_other, search.status);
}
