//! The wiki served live by the cpull workspace server at /wiki/: requests
//! for pages rebuild the site incrementally first (at most every few
//! seconds; unchanged repos cost a `git status` each), then the file is
//! served from `<root>/.pull/cpull/wiki/dist`. The site uses relative URLs,
//! so it works under the /wiki/ prefix as it does on GitHub Pages. Pages get
//! `forge_meta` on the way out, which switches on the forge features
//! (forge.zig); dist/, which `cpull wiki publish` copies, never has it.
const std = @import("std");
const wiki = @import("wiki.zig");
const Sys = @import("sys.zig").Sys;

pub const prefix = "/wiki";

/// Seconds between rebuild checks triggered by page requests.
const rebuild_interval = 5;

var mutex: std.Io.Mutex = .init;
var last_build: i64 = 0;

/// Whether `path` (the request path) belongs to the wiki.
pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or std.mem.startsWith(u8, path, prefix ++ "/");
}

/// Answer a GET/HEAD request under /wiki for the workspace at `root`.
pub fn handle(io: std.Io, gpa: std.mem.Allocator, request: *std.http.Server.Request, root: []const u8, path: []const u8) !void {
    if (std.mem.eql(u8, path, prefix)) {
        return request.respond("", .{ .status = .moved_permanently, .extra_headers = &.{.{ .name = "location", .value = prefix ++ "/" }} });
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sys: Sys = .{ .io = io, .arena = arena_state.allocator() };
    const paths = wiki.findPaths(sys, root, root) catch {
        return request.respond("this workspace has no wiki (no wiki/wiki.toml)\n", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
    };

    var rel = try decode(sys.arena, path[prefix.len + 1 ..]);
    if (rel.len == 0 or rel[rel.len - 1] == '/') rel = try std.mem.concat(sys.arena, u8, &.{ rel, "index.html" });
    if (std.mem.indexOf(u8, rel, "..") != null or std.mem.indexOfScalar(u8, rel, 0) != null) {
        return request.respond("bad path\n", .{ .status = .bad_request });
    }

    const index_exists = sys.isFile(sys.join(&.{ paths.dist, "index.html" }));
    const is_page = std.mem.endsWith(u8, rel, ".html");
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    if (!index_exists) {
        // the first request waits for the first build
        try mutex.lock(io);
        defer mutex.unlock(io);
        if (!sys.isFile(sys.join(&.{ paths.dist, "index.html" }))) rebuild(sys, paths, now);
    } else if (is_page and now - @atomicLoad(i64, &last_build, .monotonic) >= rebuild_interval) {
        // other requests keep serving the current files while one rebuilds
        if (mutex.tryLock()) {
            defer mutex.unlock(io);
            rebuild(sys, paths, now);
        }
    }

    const file = sys.join(&.{ paths.dist, rel });
    const body = blk: {
        if (sys.isDir(file)) {
            const location = try std.fmt.allocPrint(sys.arena, "{s}/", .{path});
            return request.respond("", .{ .status = .moved_permanently, .extra_headers = &.{.{ .name = "location", .value = location }} });
        }
        break :blk sys.readFile(file) catch {
            return request.respond("not found\n", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
        };
    };
    try request.respond(if (is_page) try live(sys.arena, body) else body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = contentType(rel) },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

/// What turns the wiki's forge features on (assets/forge.js: the repo's
/// cpull page, issues, CI, the reports on a page, filing a report from the
/// right-click menu): a meta tag naming the api (forge.zig), added to the
/// pages served here and never to dist/, so the published site stays static.
pub const forge_meta = "<meta name=\"cpull-wiki\" content=\"" ++ prefix ++ "/_cpull\">";

fn live(arena: std.mem.Allocator, page: []const u8) ![]const u8 {
    const head = std.mem.indexOf(u8, page, "</head>") orelse return page;
    return std.mem.concat(arena, u8, &.{ page[0..head], "  ", forge_meta, "\n", page[head..] });
}

fn rebuild(sys: Sys, paths: wiki.Paths, now: i64) void {
    @atomicStore(i64, &last_build, now, .monotonic);
    // a fresh arena per build: the request's one only lives as long as it
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const build_sys: Sys = .{ .io = sys.io, .arena = arena_state.allocator(), .env = sys.env };
    const owned: wiki.Paths = .{
        .wiki = build_sys.arena.dupe(u8, paths.wiki) catch return,
        .root = build_sys.arena.dupe(u8, paths.root) catch return,
        .build = build_sys.arena.dupe(u8, paths.build) catch return,
        .dist = build_sys.arena.dupe(u8, paths.dist) catch return,
    };
    _ = wiki.build(build_sys, owned, false) catch |err| {
        std.debug.print("wiki: live rebuild failed: {t}\n", .{err});
    };
    @atomicStore(i64, &last_build, std.Io.Timestamp.now(sys.io, .real).toSeconds(), .monotonic);
}

fn decode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            try out.append(arena, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(arena, s[i]);
    }
    return out.items;
}

pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" },
        .{ ".woff", "font/woff" },
        .{ ".ttf", "font/ttf" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".md", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml" },
        .{ ".pdf", "application/pdf" },
    };
    for (types) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return "application/octet-stream";
}

test "wiki paths" {
    try std.testing.expect(matches("/wiki/"));
    try std.testing.expect(matches("/wiki"));
    try std.testing.expect(!matches("/wikis"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", contentType("_assets/style.css"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("<html><head><title>x</title>  " ++ forge_meta ++ "\n</head></html>", try live(arena.allocator(), "<html><head><title>x</title></head></html>"));
    try std.testing.expectEqualStrings("no head", try live(arena.allocator(), "no head"));
}
