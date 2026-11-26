// a client of idlci, the workspace's CI (github.com/jbisfun/idlci), over its
// HTTP/JSON API (theme docs/workspace-tools.md §5). cpull finds it through
// discovery (`.pull/idlci/serve.addr` while its server holds serve.lock, or
// $IDLCI_ADDR) and only trusts an address whose /api/health names this
// workspace's root. Nothing here fails a page: a down or foreign idlci is
// "no CI", and the callers show none.
const std = @import("std");
const discovery = @import("discovery");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.idlci);

pub const Client = struct {
    a: Allocator,
    // on the heap: pooled connections point back at their std.http.Client,
    // so it must not move when a Client is returned or copied
    http: *std.http.Client,
    // "http://127.0.0.1:8737", no trailing slash
    base: []const u8,
    // the last failed request's {"error"} text (or the http status)
    last_error: []const u8 = "",

    // the idlci serving the workspace at `root`, or null when none is
    // running (or the address answers for another workspace). everything is
    // allocated in `a`; `deinit` closes the connections.
    pub fn connect(io: std.Io, a: Allocator, root: []const u8, environ: ?*const std.process.Environ.Map) ?Client {
        const explicit = if (environ) |env| env.get(discovery.Tool.idlci.envVar()) else null;
        const addr = if (explicit) |x| (if (x.len > 0) x else null) else null;
        const found = addr orelse (discovery.read(io, a, root, .idlci) catch null) orelse return null;
        const http = a.create(std.http.Client) catch return null;
        http.* = .{ .allocator = a, .io = io };
        var c: Client = .{ .a = a, .http = http, .base = discovery.baseUrl(a, found) catch return null };
        const health = c.get("/api/health") catch {
            c.deinit();
            return null;
        };
        if (!sameRoot(io, a, health, root)) {
            log.warn("{s} isn't the idlci of {s}; ignoring it", .{ c.base, root });
            c.deinit();
            return null;
        }
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
    }

    pub fn send(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !std.json.Value {
        var out: std.Io.Writer.Allocating = .init(c.a);
        const full = try std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path });
        const res = try c.http.fetch(.{
            .location = .{ .url = full },
            .method = method,
            .payload = payload,
            .response_writer = &out.writer,
            .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        });
        const v = std.json.parseFromSliceLeaky(std.json.Value, c.a, out.written(), .{}) catch {
            c.last_error = try std.fmt.allocPrint(c.a, "idlci answered {d} with: {s}", .{ @intFromEnum(res.status), out.written()[0..@min(out.written().len, 200)] });
            return error.IdlciError;
        };
        if (res.status.class() != .success) {
            c.last_error = errorText(v) orelse @tagName(res.status);
            return error.IdlciError;
        }
        return v;
    }

    pub fn get(c: *Client, path: []const u8) !std.json.Value {
        return c.send(.GET, path, null);
    }

    pub fn post(c: *Client, path: []const u8, body: []const u8) !std.json.Value {
        return c.send(.POST, path, body);
    }

    // an idlci path (/jobs/42) as an absolute url on its server
    pub fn url(c: *const Client, path: []const u8) []const u8 {
        if (path.len == 0 or path[0] != '/') return path;
        return std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path }) catch path;
    }
};

fn errorText(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const e = v.object.get("error") orelse return null;
    return if (e == .string) e.string else null;
}

// whether a /api/health answer names the workspace at `root` (both resolved)
fn sameRoot(io: std.Io, a: Allocator, health: std.json.Value, root: []const u8) bool {
    if (health != .object) return false;
    const served = health.object.get("root") orelse return false;
    if (served != .string) return false;
    if (std.mem.eql(u8, std.mem.trimEnd(u8, served.string, "/"), std.mem.trimEnd(u8, root, "/"))) return true;
    const cwd = std.Io.Dir.cwd();
    const x = cwd.realPathFileAlloc(io, served.string, a) catch return false;
    const y = cwd.realPathFileAlloc(io, root, a) catch return false;
    return std.mem.eql(u8, x, y);
}

// `s` percent-encoded as one query value
pub fn queryEscape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.Uri.Component.percentEncode(&out.writer, s, struct {
        fn isUnreserved(ch: u8) bool {
            return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
        }
    }.isUnreserved);
    return out.written();
}

// `s` percent-encoded as path segments ('/' kept, so "group/name" stays two)
pub fn pathEscape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.Uri.Component.percentEncode(&out.writer, s, struct {
        fn isUnreserved(ch: u8) bool {
            return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~' or ch == '/';
        }
    }.isUnreserved);
    return out.written();
}

test queryEscape {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("core%20aaa%0Alib%20bbb", try queryEscape(arena.allocator(), "core aaa\nlib bbb"));
    try std.testing.expectEqualStrings("fossify-ios/calculator-ios", try pathEscape(arena.allocator(), "fossify-ios/calculator-ios"));
}
