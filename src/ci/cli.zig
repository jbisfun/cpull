//! `cpull ci ...`: idlci's CLI (queue, jobs, log, cancel, retry) as a client of
//! the workspace server's /ci/api.
const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const default_addr = "127.0.0.1:8080";

pub const usage =
    \\usage: cpull ci <command> [--root DIR] [--addr HOST:PORT]
    \\
    \\local CI for the idl projects of a pull workspace, run by the workspace
    \\server (`pull cpull open --web-listen ADDR`; UI at http://ADDR/ci).
    \\
    \\  queue PROJECT COMMAND [TARGET...] [-c debug|release] [--strict] [-w|--wait]
    \\        COMMAND: build test lint fmt-check check clean. --wait follows the log
    \\        and exits nonzero unless the job passed.
    \\  jobs  [--status S] [--project P] [--limit N]    (also: list)
    \\  log   ID [-f|--follow]
    \\  cancel ID
    \\  retry ID
    \\
    \\--root defaults to $PULL_ROOT, else the nearest parent holding pullfile.plist;
    \\--addr to $CPULL_ADDR, else .pull/cpull/serve.addr, else 127.0.0.1:8080.
    \\
;

pub const Client = struct {
    a: Allocator,
    http: std.http.Client,
    base: []const u8,

    /// Connect to the server for `root`: `addr`, else `.pull/cpull/serve.addr`,
    /// else the default; fails unless its /ci/api/health names this root.
    pub fn connect(io: Io, a: Allocator, root: []const u8, addr_arg: ?[]const u8, err_msg: *[]const u8) !Client {
        const addr = addr_arg orelse blk: {
            const path = try std.fs.path.join(a, &.{ root, ".pull", "cpull", "serve.addr" });
            const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256)) catch break :blk default_addr;
            const t = std.mem.trim(u8, text, " \t\r\n");
            break :blk if (t.len == 0) default_addr else t;
        };
        var c: Client = .{ .a = a, .http = .{ .allocator = a, .io = io }, .base = try std.fmt.allocPrint(a, "http://{s}", .{addr}) };
        const health = c.get("/ci/api/health") catch {
            err_msg.* = try std.fmt.allocPrint(a, "the cpull workspace server isn't running for {s} at {s} (start it: pull cpull open --web-listen {s}, or pass --addr)", .{ root, addr, addr });
            return error.NotRunning;
        };
        const served = if (health == .object) health.object.get("root") else null;
        if (served == null or served.? != .string) {
            err_msg.* = try std.fmt.allocPrint(a, "{s} answers but isn't a cpull server with CI; pass --addr", .{addr});
            return error.NotRunning;
        }
        if (!std.mem.eql(u8, served.?.string, root)) {
            err_msg.* = try std.fmt.allocPrint(a, "{s} is a cpull server for {s}, not {s}; pass --addr", .{ addr, served.?.string, root });
            return error.NotRunning;
        }
        return c;
    }

    pub const RequestError = error{ServerError};

    /// The server's `{"error": ...}` for the last failed request.
    pub var last_error: []const u8 = "";

    fn send(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !std.json.Value {
        var out: std.Io.Writer.Allocating = .init(c.a);
        const url = try std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path });
        const res = try c.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &out.writer,
            .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        });
        const v = std.json.parseFromSliceLeaky(std.json.Value, c.a, out.written(), .{}) catch {
            last_error = try std.fmt.allocPrint(c.a, "decoding response: {s}", .{out.written()});
            return error.ServerError;
        };
        if (res.status.class() != .success) {
            last_error = if (v == .object) if (v.object.get("error")) |e| (if (e == .string) e.string else @tagName(res.status)) else @tagName(res.status) else @tagName(res.status);
            return error.ServerError;
        }
        return v;
    }

    pub fn get(c: *Client, path: []const u8) !std.json.Value {
        return c.send(.GET, path, null);
    }

    pub fn post(c: *Client, path: []const u8, body: []const u8) !std.json.Value {
        return c.send(.POST, path, body);
    }
};

/// A Job from the API's JSON.
pub fn parseJob(a: Allocator, v: std.json.Value) !db.Job {
    const o = v.object;
    const str = struct {
        fn s(obj: std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const x = obj.get(k) orelse return null;
            return if (x == .string) x.string else null;
        }
        fn i(obj: std.json.ObjectMap, k: []const u8) ?i64 {
            const x = obj.get(k) orelse return null;
            return if (x == .integer) x.integer else null;
        }
        fn b(obj: std.json.ObjectMap, k: []const u8) bool {
            const x = obj.get(k) orelse return false;
            return x == .bool and x.bool;
        }
    };
    var targets: std.ArrayList([]const u8) = .empty;
    if (o.get("targets")) |t| if (t == .array) for (t.array.items) |x| if (x == .string) try targets.append(a, x.string);
    return .{
        .id = str.i(o, "id") orelse return error.InvalidJob,
        .project = str.s(o, "project") orelse "",
        .command = db.Command.parse(str.s(o, "command") orelse "") orelse return error.InvalidJob,
        .targets = targets.items,
        .configuration = db.Configuration.parse(str.s(o, "configuration") orelse "") orelse .none,
        .strict = str.b(o, "strict"),
        .status = db.Status.parse(str.s(o, "status") orelse "") orelse return error.InvalidJob,
        .exit_code = if (str.i(o, "exit_code")) |c| @intCast(c) else null,
        .created = str.i(o, "created") orelse 0,
        .started = str.i(o, "started"),
        .finished = str.i(o, "finished"),
        .git = .{ .repo = str.s(o, "repo"), .branch = str.s(o, "branch"), .head = str.s(o, "head"), .dirty = str.b(o, "dirty") },
        .requested_by = db.RequestedBy.parse(str.s(o, "requested_by") orelse "") orelse .cli,
        .retry_of = str.i(o, "retry_of"),
        .log = str.s(o, "log") orelse "",
    };
}

/// The workspace root: --root, else $PULL_ROOT, else the nearest parent with pullfile.plist.
pub fn findRoot(io: Io, a: Allocator, arg: ?[]const u8, env: *const std.process.Environ.Map, cwd: []const u8) ![]const u8 {
    const root = arg orelse env.get("PULL_ROOT") orelse blk: {
        var dir: ?[]const u8 = cwd;
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const p = try std.fs.path.join(a, &.{ d, "pullfile.plist" });
            const st = Io.Dir.cwd().statFile(io, p, .{}) catch null;
            if (st != null and st.?.kind == .file) break :blk d;
        }
        return error.NoWorkspaceRoot;
    };
    const abs = try std.fs.path.resolve(a, &.{ cwd, root });
    return Io.Dir.cwd().realPathFileAlloc(io, abs, a);
}

const Parsed = struct {
    positional: std.ArrayList([]const u8) = .empty,
    root: ?[]const u8 = null,
    addr: ?[]const u8 = null,
    configuration: db.Configuration = .none,
    strict: bool = false,
    wait: bool = false,
    follow: bool = false,
    status: ?[]const u8 = null,
    project: ?[]const u8 = null,
    limit: usize = 20,
};

/// Run `cpull ci ARGS...` (args after "ci"); returns the exit code.
pub fn run(io: Io, a: Allocator, args: []const []const u8, env: *const std.process.Environ.Map, cwd: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = struct {
            fn v(list: []const []const u8, idx: *usize, name: []const u8, e: *std.Io.Writer) ?[]const u8 {
                if (idx.* + 1 >= list.len) {
                    e.print("error: {s} needs a value\n\n{s}", .{ name, usage }) catch {};
                    return null;
                }
                idx.* += 1;
                return list[idx.*];
            }
        }.v;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            try out.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--root")) {
            p.root = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--addr")) {
            p.addr = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--configuration")) {
            const c = value(args, &i, arg, err) orelse return 2;
            p.configuration = db.Configuration.parse(c) orelse {
                try err.print("error: invalid configuration '{s}' [possible values: debug, release, none]\n", .{c});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--strict")) {
            p.strict = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wait")) {
            p.wait = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            p.follow = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            p.status = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--project")) {
            p.project = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const l = value(args, &i, arg, err) orelse return 2;
            p.limit = std.fmt.parseInt(usize, l, 10) catch {
                try err.print("error: invalid --limit '{s}'\n", .{l});
                return 2;
            };
        } else if (arg.len > 1 and arg[0] == '-') {
            try err.print("error: unexpected argument '{s}' found\n\n{s}", .{ arg, usage });
            return 2;
        } else try p.positional.append(a, arg);
    }
    const pos = p.positional.items;
    if (pos.len == 0) {
        try err.writeAll(usage);
        return 2;
    }
    const cmd = pos[0];
    const known = [_][]const u8{ "queue", "jobs", "list", "log", "cancel", "retry" };
    if (for (known) |k| (if (std.mem.eql(u8, k, cmd)) break false) else true) {
        try err.print("error: unrecognized subcommand '{s}'\n\n{s}", .{ cmd, usage });
        return 2;
    }

    const root = findRoot(io, a, p.root, env, cwd) catch |e| {
        try err.print("Error: {s}\n", .{if (e == error.NoWorkspaceRoot) "no workspace root: pass --root, set PULL_ROOT, or run inside a pull workspace" else @errorName(e)});
        return 1;
    };
    var msg: []const u8 = "";
    var c = Client.connect(io, a, root, p.addr orelse env.get("CPULL_ADDR"), &msg) catch {
        try err.print("Error: {s}\n", .{msg});
        return 1;
    };
    return command(io, a, &c, cmd, pos[1..], p, out, err) catch |e| {
        if (e == error.ServerError) try err.print("Error: {s}\n", .{Client.last_error}) else try err.print("Error: {t}\n", .{e});
        return 1;
    };
}

fn needId(pos: []const []const u8, err: *std.Io.Writer) !?i64 {
    if (pos.len != 1) {
        try err.print("error: expected one job ID\n\n{s}", .{usage});
        return null;
    }
    return std.fmt.parseInt(i64, pos[0], 10) catch {
        try err.print("error: invalid job ID '{s}'\n", .{pos[0]});
        return null;
    };
}

fn command(io: Io, a: Allocator, c: *Client, cmd: []const u8, pos: []const []const u8, p: Parsed, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (std.mem.eql(u8, cmd, "queue")) {
        if (pos.len < 2) {
            try err.print("error: queue needs PROJECT and COMMAND\n\n{s}", .{usage});
            return 2;
        }
        const command_v = db.Command.parse(pos[1]) orelse {
            try err.print("error: invalid value '{s}' for '<COMMAND>' [possible values: build, test, lint, fmt-check, check, clean]\n", .{pos[1]});
            return 2;
        };
        const new: db.NewJob = .{ .project = pos[0], .command = command_v, .targets = pos[2..], .configuration = p.configuration, .strict = p.strict, .requested_by = .cli };
        const v = try c.post("/ci/api/jobs", try std.json.Stringify.valueAlloc(a, new, .{}));
        const job = try parseJob(a, v);
        const dedup = v.object.get("deduplicated");
        try out.print("{s}{s}\n", .{ try job.summary(a), if (dedup != null and dedup.? == .bool and dedup.?.bool) " (already queued)" else "" });
        try out.flush();
        if (p.wait) {
            const done = try follow(io, a, c, job.id, out);
            if (done.status != .passed) {
                try err.print("Error: job #{d} {t}\n", .{ done.id, done.status });
                return 1;
            }
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "jobs") or std.mem.eql(u8, cmd, "list")) {
        if (pos.len != 0) {
            try err.print("error: unexpected argument '{s}' found\n", .{pos[0]});
            return 2;
        }
        var q: std.Io.Writer.Allocating = .init(a);
        try q.writer.print("/ci/api/jobs?limit={d}", .{p.limit});
        const enc = struct {
            fn ok(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/';
            }
        }.ok;
        if (p.status) |s| {
            if (db.Status.parse(s) == null) {
                try err.print("error: invalid value '{s}' for '--status' [possible values: queued, running, passed, failed, cancelled]\n", .{s});
                return 2;
            }
            try q.writer.print("&status={s}", .{s});
        }
        if (p.project) |pr| {
            try q.writer.writeAll("&project=");
            try std.Uri.Component.percentEncode(&q.writer, pr, enc);
        }
        const v = try c.get(q.written());
        for (v.array.items) |j| try out.print("{s}\n", .{try (try parseJob(a, j)).summary(a)});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "log")) {
        const id = try needId(pos, err) orelse return 2;
        if (p.follow) {
            _ = try follow(io, a, c, id, out);
            return 0;
        }
        const v = try c.get(try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/log?tail=1000000", .{id}));
        try out.print("{s}\n", .{v.object.get("text").?.string});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "cancel")) {
        const id = try needId(pos, err) orelse return 2;
        const v = try c.post(try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/cancel", .{id}), "null");
        try out.print("{s}\n", .{try (try parseJob(a, v)).summary(a)});
        return 0;
    }
    // retry
    const id = try needId(pos, err) orelse return 2;
    const v = try c.post(try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/retry?by=cli", .{id}), "null");
    try out.print("{s}\n", .{try (try parseJob(a, v)).summary(a)});
    return 0;
}

/// Stream a job's log to `out` until it finishes.
fn follow(io: Io, a: Allocator, c: *Client, id: i64, out: *std.Io.Writer) !db.Job {
    var offset: u64 = 0;
    while (true) {
        const v = try c.get(try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/log?offset={d}", .{ id, offset }));
        const o = v.object;
        const text = o.get("text").?.string;
        try out.writeAll(text);
        try out.flush();
        offset = @intCast(o.get("next_offset").?.integer);
        const size: u64 = @intCast(o.get("size").?.integer);
        const status = db.Status.parse(o.get("status").?.string) orelse .failed;
        if (status.isFinal() and offset >= size) return parseJob(a, try c.get(try std.fmt.allocPrint(a, "/ci/api/jobs/{d}", .{id})));
        if (text.len == 0) io.sleep(.fromSeconds(1), .awake) catch {};
    }
}
