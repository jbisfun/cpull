const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const cmd = @import("./command.zig");
const srv = @import("./serve.zig");
const ui = @import("./ui.zig");
const web = @import("./web.zig");
const ws = @import("./workspace.zig");
const ci = @import("./ci/ci.zig");

// cook the terminal before a panic/segfault trace is printed, so the trace
// isn't mangled by raw mode and the alternate buffer
pub const std_options_debug_io = xit.xitui.terminal.crash_debug_io;

// the web UI: the jbisfun wiki theme (src/frontend), unless built with
// -Dfrontend=classic, which keeps haxy's own terminal-grid web UI
pub const haxy_frontend: web.Frontend = if (@import("frontend_options").themed) @import("frontend/haxy/frontend.zig").frontend else .{};

pub const RunOpts = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    // the user's global git config, used for the commit identity in local mode.
    // null by default so tests and the server paths never read it.
    global_config_path: ?[]const u8 = null,
    // false when NO_COLOR is set, so the TUI draws without colors
    color: bool = true,
    // the process environment, which CI jobs inherit
    environ: ?*const std.process.Environ.Map = null,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        try args.append(allocator, arg);
    }

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});

    var environ_map = try std.process.Environ.createMap(init.minimal.environ, allocator);
    defer environ_map.deinit();
    const global_config_path = try xit.config.globalConfigPath(io, allocator, &environ_map);
    defer if (global_config_path) |path| allocator.free(path);

    const run_opts = RunOpts{
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
        .global_config_path = global_config_path,
        .color = std.mem.eql(u8, environ_map.get("NO_COLOR") orelse "", ""),
        .environ = &environ_map,
    };

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    // `cpull ci ...`: the CI's client commands
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "ci")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const code = try ci.cli.run(io, arena.allocator(), args.items[1..], &environ_map, cwd_path, run_opts.out, run_opts.err);
        try run_opts.out.flush();
        try run_opts.err.flush();
        return code;
    }

    run(.xit, .{}, io, allocator, args.items, cwd_path, run_opts) catch |err| switch (err) {
        error.HandledError => return 1,
        else => |e| return e,
    };

    return 0;
}

pub fn run(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd_path: []const u8,
    run_opts: RunOpts,
) !void {
    var cmd_args = try cmd.CommandArgs.init(allocator, args);
    defer cmd_args.deinit();

    switch (try cmd.CommandDispatch.init(&cmd_args)) {
        .invalid => |invalid| switch (invalid) {
            .command => |command| {
                try run_opts.err.print("\"{s}\" is not a valid command\n\n", .{command});
                try cmd.printHelp(null, run_opts.err);
                return error.HandledError;
            },
            .argument => |argument| {
                try run_opts.err.print("\"{s}\" is not a valid argument\n\n", .{argument.value});
                try cmd.printHelp(argument.command, run_opts.err);
                return error.HandledError;
            },
        },
        .help => |cmd_kind_maybe| try cmd.printHelp(cmd_kind_maybe, run_opts.out),
        .local => |local_opts| {
            // session-lifetime allocations (the repo path, session state)
            var session_arena = std.heap.ArenaAllocator.init(allocator);
            defer session_arena.deinit();

            // probe both backends for a repo; the nearest one wins, so a repo
            // isn't shadowed by one it is nested inside. only the work path
            // and backend kind are kept; pages re-open the repo on each build.
            const found: ?ui.RepoSource = blk: {
                var found: ?ui.RepoSource = null;
                inline for ([_]rp.RepoKind{ .git, .xit }) |probe_kind| {
                    if (rp.AnyRepo(probe_kind, .{}).open(io, allocator, .{ .path = cwd_path })) |repo| {
                        var opened = repo;
                        defer opened.deinit(io, allocator);
                        const work_path = switch (opened) {
                            inline else => |*r| r.core.work_path,
                        };
                        const found_len = if (found) |f| f.path.len else 0;
                        if (work_path.len > found_len) {
                            found = .{
                                .path = try session_arena.allocator().dupe(u8, work_path),
                                .repo_kind = probe_kind,
                                .global_config_path = run_opts.global_config_path,
                            };
                        }
                    } else |err| switch (err) {
                        error.RepoNotFound => {},
                        else => |e| return e,
                    }
                }
                break :blk found;
            };

            // a pull workspace around the current dir, unless one of its
            // repos is nearer, or the one --workspace names
            const workspace_root: ?[]const u8 = if (local_opts.workspace_path) |arg|
                try std.Io.Dir.path.resolve(session_arena.allocator(), &.{ cwd_path, arg })
            else
                try ws.detect(io, session_arena.allocator(), cwd_path, if (found) |f| f.path else null);

            var workspace: ?*ws.Workspace = null;
            if (workspace_root) |root| {
                workspace = ws.Workspace.load(io, allocator, session_arena.allocator(), root, run_opts.global_config_path) catch |err| {
                    try run_opts.err.print("can't read the pull workspace at {s}: {s}\n", .{ root, @errorName(err) });
                    return error.HandledError;
                };
            }
            if (workspace == null and found == null) {
                try run_opts.err.print("no git or xit repo found in the current directory\n", .{});
                return error.HandledError;
            }

            var session = ui.Session{
                .arena = &session_arena,
                .page_arena = &session_arena,
                .io = io,
                .local = if (workspace == null) found else null,
                .workspace_host = if (workspace) |w| &w.host else null,
                .is_terminal = true,
                .color = run_opts.color,
                .data = .{
                    // the files root; local routes carry no identity
                    .current_page = if (workspace != null) .{ .workspace = .{} } else .{ .repo_files = .{ .name = .{} } },
                    .host_kind = .local,
                    .workspace = if (workspace) |w| w.name else null,
                },
            };

            // serve the web UI in the background while the TUI runs in the
            // foreground; the footer points at whatever port it bound.
            const Runnable = struct {
                io: std.Io,
                allocator: std.mem.Allocator,
                session: *ui.Session,

                pub fn run(self: @This(), web_url: []const u8) !void {
                    self.session.web_url = web_url;
                    try ui.run(self.io, self.allocator, self.session, null);
                }
            };

            var local: web.LocalHost = if (workspace) |w| .{ .workspace = &w.host, .workspace_name = w.name } else .{ .source = found };
            // a workspace runs its CI too, under /ci
            var mounts: [1]web.Mount = undefined;
            if (workspace) |w| if (run_opts.environ) |environ| {
                const ci_app = ci.App.init(io, allocator, w.root, environ, .{
                    .jobs = local_opts.ci_jobs,
                    .watch = if (local_opts.ci_watch) local_opts.ci_watch_interval else null,
                    .listen = local_opts.web_listen,
                    .workspace_name = w.name,
                }) catch |err| blk: {
                    try run_opts.err.print("ci disabled: {s}\n", .{@errorName(err)});
                    break :blk null;
                };
                if (ci_app) |app| {
                    mounts[0] = .{ .prefix = ci.web.prefix, .ctx = app, .handle = ci.web.handle };
                    local.mounts = &mounts;
                }
            };
            try srv.runLocal(io, allocator, local, local_opts.web_listen, run_opts.err, Runnable{ .io = io, .allocator = allocator, .session = &session });
        },
        .cli => |cli_cmd| switch (cli_cmd) {
            .serve => |options| try srv.run(repo_kind, any_repo_opts, io, allocator, cwd_path, options, run_opts.err, {}),
            .delete_user => |options| try srv.deleteUser(io, allocator, cwd_path, options, run_opts.out, run_opts.err),
            .stack => |options| try ws.runStackCommand(io, allocator, cwd_path, options, run_opts.global_config_path, run_opts.out, run_opts.err),
        },
    }
}
