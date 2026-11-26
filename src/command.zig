const std = @import("std");
const srv = @import("./serve.zig");

pub const CommandKind = enum {
    serve,
    delete_user,
    stack,
    report,
    wiki,
};

const Help = struct {
    name: []const u8,
    descrip: []const u8,
    example: []const u8,
};

fn commandHelp(command_kind: CommandKind) Help {
    return switch (command_kind) {
        .serve => .{
            .name = "serve",
            .descrip =
            \\a long-running server forwarding receive-pack and upload-pack.
            ,
            .example =
            \\cpull serve --web-listen 127.0.0.1:8080 --ssh-listen 127.0.0.1:8022 --data-dir /srv/git
            \\use "none" for --ssh-listen to disable ssh. git clones over HTTP share the web UI's listener.
            \\--web-url and --ssh-url set the public urls shown to users, like https://example.com and ssh://example.com.
            \\--max-repo-size caps each repo's on-disk size, like 1G, rejecting pushes past it. no limit by default.
            \\--temp-dir is where scratch files go instead of each repo's dir. useful when --data-dir is on a network volume.
            ,
        },
        .stack => .{
            .name = "stack",
            .descrip =
            \\changes that span the repos of a pull workspace, landed together.
            \\new opens one patch per member (REPO:SOURCE[:TARGET], the target
            \\defaulting to the pullfile branch) and the stack naming them, in the
            \\workspace's events repo. merge merges every member or none, marks
            \\them merged and prints the commits to pin; with the pullfile's
            \\cpull.require_ci it refuses until the stack's CI is green, unless
            \\--force. show and list print json.
            ,
            .example =
            \\cpull stack new --title "rename the api" core:feature app/web:feature
            \\cpull stack merge 5f1c
            \\cpull stack show 5f1c
            \\--workspace DIR names the workspace; by default, the one around the current dir.
            ,
        },
        .report => .{
            .name = "report",
            .descrip =
            \\line-anchored issues in a pull workspace (what radar was): a line of
            \\code plus a note, filed as an issue in the repo it points at ("." =
            \\the workspace's events repo). the line text is read from the file.
            \\list, show, close and reopen take every repo's reports; an id prefix
            \\will do. migrate files `radar list --all --json` output ("-" = stdin).
            ,
            .example =
            \\cpull report pull src/main.zig 42 -q "unwrap()" -n "panics on an empty pullfile"
            \\cpull report list [--all] [--json]
            \\cpull report show 5f1c / close 5f1c / reopen 5f1c
            \\cpull report migrate radar.json
            \\--title, --labels and --source (default cli) set those fields; --json prints json.
            ,
        },
        .wiki => .{
            .name = "wiki",
            .descrip =
            \\the workspace wiki: a static site from every repo's README, docs/
            \\and code reference, with <workspace>/wiki as its data (wiki.toml,
            \\templates, pages, locales, translations). build writes it to
            \\.pull/cpull/wiki/dist, regenerating only what changed; publish also
            \\mirrors it into jbisfun.github.io and stages it. the workspace web
            \\server serves it live at /wiki/.
            ,
            .example =
            \\cpull wiki build
            \\cpull wiki build --force
            \\cpull wiki publish
            \\cpull wiki clean
            \\--workspace DIR names the workspace; by default, the one around the current dir.
            ,
        },
        .delete_user => .{
            .name = "delete-user",
            .descrip =
            \\delete a user and everything they own, without their password.
            ,
            .example =
            \\cpull delete-user alice --data-dir /srv/git
            \\safe to run while the server is up.
            ,
        },
    };
}

pub fn printHelp(cmd_kind_maybe: ?CommandKind, writer: *std.Io.Writer) !void {
    const print_indent = comptime blk: {
        var indent = 0;
        for (0..@typeInfo(CommandKind).@"enum".field_names.len) |i| {
            indent = @max(commandHelp(@fromBackingInt(@intCast(i))).name.len, indent);
        }
        indent += 2;
        break :blk indent;
    };

    if (cmd_kind_maybe) |cmd_kind| {
        const help = commandHelp(cmd_kind);
        // name and description
        try writer.print("{s}", .{help.name});
        for (0..print_indent - help.name.len) |_| try writer.print(" ", .{});
        var split_iter = std.mem.splitScalar(u8, help.descrip, '\n');
        try writer.print("{s}\n", .{split_iter.first()});
        while (split_iter.next()) |line| {
            for (0..print_indent) |_| try writer.print(" ", .{});
            try writer.print("{s}\n", .{line});
        }
        try writer.print("\n", .{});
        // example
        split_iter = std.mem.splitScalar(u8, help.example, '\n');
        while (split_iter.next()) |line| {
            for (0..print_indent) |_| try writer.print(" ", .{});
            try writer.print("{s}\n", .{line});
        }
    } else {
        try writer.print("help: cpull <command> [<args>]\n\n", .{});
        try writer.print(
            \\with no command, cpull opens the TUI (and a web UI on a local port) for the
            \\repo or pull workspace around the current dir. local mode has no accounts:
            \\writes are authored by the repo's user.name and user.email.
            \\  --workspace DIR     view the pull workspace at DIR
            \\  --web-listen ADDR   no TUI: serve only the web UI on ADDR (like
            \\                      127.0.0.1:8080) until killed, e.g. as a pull job
            \\a workspace also runs its idl projects' CI at /ci (`ci --help`):
            \\  --ci-jobs N         concurrent CI jobs (default 1)
            \\  --ci-watch          queue build + test when a project's HEAD moves
            \\  --ci-watch-interval SECS  between HEAD polls (default 15)
            \\
            \\
        , .{});
        inline for (@typeInfo(CommandKind).@"enum".field_values) |value| {
            const help = commandHelp(@fromBackingInt(@intCast(value)));
            // name and description
            try writer.print("{s}", .{help.name});
            for (0..print_indent - help.name.len) |_| try writer.print(" ", .{});
            var split_iter = std.mem.splitScalar(u8, help.descrip, '\n');
            try writer.print("{s}\n", .{split_iter.first()});
            while (split_iter.next()) |line| {
                for (0..print_indent) |_| try writer.print(" ", .{});
                try writer.print("{s}\n", .{line});
            }
        }
    }
}

pub const CommandArgs = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    command_kind: ?CommandKind,
    command_name: ?[]const u8,
    positional_args: []const []const u8,
    map_args: std.StringArrayHashMapUnmanaged(?[]const u8),
    unused_args: std.StringArrayHashMapUnmanaged(void),

    // flags that can have a value associated with them
    // must be included here
    const value_flags = std.StaticStringMap(void).initComptime(.{
        .{"--web-listen"},
        .{"--ssh-listen"},
        .{"--web-url"},
        .{"--ssh-url"},
        .{"--max-repo-size"},
        .{"--data-dir"},
        .{"--temp-dir"},
        .{"--workspace"},
        .{"--title"},
        .{"--description"},
        .{"--labels"},
        .{"-q"},
        .{"--quote"},
        .{"-n"},
        .{"--note"},
        .{"--source"},
        .{"--ci-jobs"},
        .{"--ci-watch-interval"},
    });

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) !CommandArgs {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        var positional_args: std.ArrayList([]const u8) = .empty;
        var map_args: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        var unused_args: std.StringArrayHashMapUnmanaged(void) = .empty;

        for (args) |arg| {
            if (arg.len > 1 and arg[0] == '-') {
                try map_args.put(arena.allocator(), arg, null);
                try unused_args.put(arena.allocator(), arg, {});
            } else {
                // if the last key is a value flag and doesn't have a value yet,
                // set this arg as its value
                const keys = map_args.keys();
                if (keys.len > 0) {
                    const last_key = keys[keys.len - 1];
                    if (map_args.get(last_key)) |last_val| {
                        if (value_flags.has(last_key) and last_val == null) {
                            try map_args.put(arena.allocator(), last_key, arg);
                            continue;
                        }
                    }
                }

                // in any other case, just consider it a positional arg
                try positional_args.append(arena.allocator(), arg);
            }
        }

        const args_slice = try positional_args.toOwnedSlice(arena.allocator());
        if (args_slice.len == 0) {
            return .{
                .allocator = allocator,
                .arena = arena,
                .command_kind = null,
                .command_name = null,
                .positional_args = args_slice,
                .map_args = map_args,
                .unused_args = unused_args,
            };
        } else {
            const command_name = args_slice[0];
            const extra_args = args_slice[1..];

            const command_kind: ?CommandKind = inline for (0..@typeInfo(CommandKind).@"enum".field_names.len) |i| {
                if (std.mem.eql(u8, command_name, commandHelp(@fromBackingInt(@intCast(i))).name)) {
                    break @fromBackingInt(@intCast(i));
                }
            } else null;

            return .{
                .allocator = allocator,
                .arena = arena,
                .command_kind = command_kind,
                .command_name = command_name,
                .positional_args = extra_args,
                .map_args = map_args,
                .unused_args = unused_args,
            };
        }
    }

    pub fn deinit(self: *CommandArgs) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn contains(self: *CommandArgs, arg: []const u8) bool {
        _ = self.unused_args.orderedRemove(arg);
        return self.map_args.contains(arg);
    }

    pub fn get(self: *CommandArgs, comptime arg: []const u8) ??[]const u8 {
        comptime std.debug.assert(value_flags.has(arg)); // can only call `get` with flags included in `value_flags`
        _ = self.unused_args.orderedRemove(arg);
        return self.map_args.get(arg);
    }
};

/// parses the args into a format that can be directly used by a repo.
/// if any additional allocation needs to be done, the arena inside the cmd args will be used.
pub const StackOptions = struct {
    action: enum { new, merge, show, list },
    // the members (new) or the stack id (merge, show)
    args: []const []const u8 = &.{},
    workspace_path: ?[]const u8 = null,
    title: []const u8 = "",
    description: []const u8 = "",
    labels: []const u8 = "",
    // merge: past the pullfile's CI gate (`cpull.require_ci`)
    force: bool = false,
};

pub const ReportOptions = @import("report/report.zig").Options;

// `cpull` with no command: local mode
pub const LocalOptions = struct {
    // the pull workspace to view instead of the repo around the current dir
    workspace_path: ?[]const u8 = null,
    // serve only the web UI, on exactly this address, until killed: no TUI
    // and no accounts, for running as a background job
    web_listen: ?[]const u8 = null,
    // the CI (src/ci) in a workspace: concurrent jobs, and whether to queue
    // build + test when a project's git HEAD moves, polled every interval
    ci_jobs: usize = 1,
    ci_watch: bool = false,
    ci_watch_interval: u64 = 15,
};

pub const Command = union(CommandKind) {
    serve: srv.Options,
    delete_user: srv.DeleteUserOptions,
    stack: StackOptions,
    report: ReportOptions,
    wiki: @import("wiki/wiki.zig").Options,

    pub fn initMaybe(cmd_args: *CommandArgs) !?Command {
        const command_kind = cmd_args.command_kind orelse return null;
        switch (command_kind) {
            .serve => {
                return .{ .serve = try serveOptions(cmd_args) orelse return null };
            },
            .delete_user => {
                if (cmd_args.positional_args.len != 1) return null;
                var options: srv.DeleteUserOptions = .{ .name = cmd_args.positional_args[0] };
                if (cmd_args.get("--data-dir")) |value_maybe| options.data_path = value_maybe orelse return error.DataDirNeedsValue;
                return .{ .delete_user = options };
            },
            .stack => {
                const positional = cmd_args.positional_args;
                if (positional.len == 0) return null;
                const action = std.meta.stringToEnum(@FieldType(StackOptions, "action"), positional[0]) orelse return null;
                var options: StackOptions = .{ .action = action, .args = positional[1..] };
                switch (action) {
                    .new => if (options.args.len == 0) return null,
                    .merge, .show => if (options.args.len != 1) return null,
                    .list => if (options.args.len != 0) return null,
                }
                if (cmd_args.get("--workspace")) |value_maybe| options.workspace_path = value_maybe orelse return error.WorkspaceNeedsValue;
                if (cmd_args.get("--title")) |value_maybe| options.title = value_maybe orelse return error.TitleNeedsValue;
                if (cmd_args.get("--description")) |value_maybe| options.description = value_maybe orelse return error.DescriptionNeedsValue;
                if (cmd_args.get("--labels")) |value_maybe| options.labels = value_maybe orelse return error.LabelsNeedsValue;
                options.force = cmd_args.contains("--force");
                return .{ .stack = options };
            },
            .report => {
                const action, const rest = @import("report/report.zig").parseAction(cmd_args.positional_args) orelse return null;
                var options: ReportOptions = .{ .action = action, .args = rest };
                if (cmd_args.get("--workspace")) |value_maybe| options.workspace_path = value_maybe orelse return error.WorkspaceNeedsValue;
                inline for (.{ "-q", "--quote" }) |flag| if (cmd_args.get(flag)) |value_maybe| {
                    options.quote = value_maybe orelse return error.QuoteNeedsValue;
                };
                inline for (.{ "-n", "--note" }) |flag| if (cmd_args.get(flag)) |value_maybe| {
                    options.note = value_maybe orelse return error.NoteNeedsValue;
                };
                if (cmd_args.get("--title")) |value_maybe| options.title = value_maybe orelse return error.TitleNeedsValue;
                if (cmd_args.get("--labels")) |value_maybe| options.labels = value_maybe orelse return error.LabelsNeedsValue;
                if (cmd_args.get("--source")) |value_maybe| options.source = value_maybe orelse return error.SourceNeedsValue;
                options.all = cmd_args.contains("--all");
                options.json = cmd_args.contains("--json");
                return .{ .report = options };
            },
            .wiki => {
                const positional = cmd_args.positional_args;
                if (positional.len != 1) return null;
                const Options = @import("wiki/wiki.zig").Options;
                const action = std.meta.stringToEnum(@FieldType(Options, "action"), positional[0]) orelse return null;
                var options: Options = .{ .action = action, .force = cmd_args.contains("--force") };
                if (cmd_args.get("--workspace")) |value_maybe| options.workspace_path = value_maybe orelse return error.WorkspaceNeedsValue;
                return .{ .wiki = options };
            },
        }
    }
};

pub fn parseServeOptions(allocator: std.mem.Allocator, args: []const []const u8) !srv.Options {
    var cmd_args = try CommandArgs.init(allocator, args);
    defer cmd_args.deinit();
    const options = try serveOptions(&cmd_args) orelse return error.InvalidServeArgument;
    if (cmd_args.unused_args.count() != 0) return error.InvalidServeArgument;
    return options;
}

fn serveOptions(cmd_args: *CommandArgs) !?srv.Options {
    if (cmd_args.positional_args.len != 0) return null;

    var options: srv.Options = .{};
    if (cmd_args.get("--web-listen")) |value_maybe| options.web_listen = value_maybe orelse return error.WebListenNeedsValue;
    if (cmd_args.get("--ssh-listen")) |value_maybe| {
        const value = value_maybe orelse return error.SshListenNeedsValue;
        options.ssh_listen = if (std.mem.eql(u8, value, "none")) null else value;
    }
    // urls are joined with "/" + a path
    if (cmd_args.get("--web-url")) |value_maybe| options.web_url = std.mem.trimEnd(u8, value_maybe orelse return error.WebUrlNeedsValue, "/");
    if (cmd_args.get("--ssh-url")) |value_maybe| options.ssh_url = std.mem.trimEnd(u8, value_maybe orelse return error.SshUrlNeedsValue, "/");
    if (cmd_args.get("--max-repo-size")) |value_maybe| options.max_repo_size = try parseSize(value_maybe orelse return error.MaxRepoSizeNeedsValue);
    if (cmd_args.get("--data-dir")) |value_maybe| options.data_path = value_maybe orelse return error.DataDirNeedsValue;
    if (cmd_args.get("--temp-dir")) |value_maybe| options.temp_path = value_maybe orelse return error.TempDirNeedsValue;
    return options;
}

// a byte count with an optional K, M or G suffix
fn parseSize(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidSize;
    const shift: u6 = switch (value[value.len - 1]) {
        'K', 'k' => 10,
        'M', 'm' => 20,
        'G', 'g' => 30,
        else => 0,
    };
    const digits = if (shift == 0) value else value[0 .. value.len - 1];
    const count = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidSize;
    return std.math.shlExact(u64, count, shift) catch error.InvalidSize;
}

/// parses the given args into a command if valid, and determines how it should be run
/// (via the TUI or CLI).
pub const CommandDispatch = union(enum) {
    invalid: union(enum) {
        command: []const u8,
        argument: struct {
            command: ?CommandKind,
            value: []const u8,
        },
    },
    help: ?CommandKind,
    // local mode, over a pull workspace when one is named
    local: LocalOptions,
    cli: Command,

    pub fn init(cmd_args: *CommandArgs) !CommandDispatch {
        const dispatch = try initIgnoreUnused(cmd_args);
        if (cmd_args.unused_args.count() > 0) {
            return .{
                .invalid = .{
                    .argument = .{
                        .command = switch (dispatch) {
                            .invalid => return dispatch, // if there was already an error, return it instead
                            .help => |cmd_kind_maybe| cmd_kind_maybe,
                            .local => null,
                            .cli => |command| command,
                        },
                        .value = cmd_args.unused_args.keys()[0],
                    },
                },
            };
        }
        return dispatch;
    }

    pub fn initIgnoreUnused(cmd_args: *CommandArgs) !CommandDispatch {
        const show_help = cmd_args.contains("--help");

        if (cmd_args.command_kind) |command_kind| {
            if (show_help) {
                return .{ .help = command_kind };
            } else if (try Command.initMaybe(cmd_args)) |cmd| {
                return .{ .cli = cmd };
            } else {
                return .{ .help = command_kind };
            }
        } else if (cmd_args.command_name) |command_name| {
            return .{ .invalid = .{ .command = command_name } };
        } else if (show_help) {
            return .{ .help = null };
        } else {
            var options: LocalOptions = .{};
            if (cmd_args.get("--workspace")) |value_maybe| options.workspace_path = value_maybe orelse return error.WorkspaceNeedsValue;
            if (cmd_args.get("--web-listen")) |value_maybe| options.web_listen = value_maybe orelse return error.WebListenNeedsValue;
            if (cmd_args.get("--ci-jobs")) |value_maybe| options.ci_jobs = std.fmt.parseInt(usize, value_maybe orelse return error.CiJobsNeedsValue, 10) catch return error.InvalidCiJobs;
            if (cmd_args.get("--ci-watch-interval")) |value_maybe| options.ci_watch_interval = std.fmt.parseInt(u64, value_maybe orelse return error.CiWatchIntervalNeedsValue, 10) catch return error.InvalidCiWatchInterval;
            options.ci_watch = cmd_args.contains("--ci-watch");
            return .{ .local = options };
        }
    }
};
