// the workspace pages of a pull workspace (ui/Workspace.zig): the repos as
// idlci's dashboard table, the issues, patches and stacks across them, and a
// stack with its members and the merge form.
const std = @import("std");
const ui = @import("../../../ui.zig");
const theme = @import("theme");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const markdown = @import("../markdown.zig");
// CI status and the stack merge gate (src/tools)
const ci_view = @import("../../../tools/view.zig");
const Ctx = ctx.Ctx;
const Workspace = ui.Workspace;

const RepoRow = struct {
    name: []const u8,
    avatar: theme.vin.Str,
    // what repoAvatar draws from, for the sidebar's smaller copy
    icon_name: []const u8,
    href: []const u8,
    group: []const u8,
    ball: []const u8,
    state: []const u8,
    cloned: bool,
    branch: []const u8,
    head_branch: []const u8,
    head: []const u8,
    pin: []const u8,
    off_branch: bool,
    issues: usize,
    issues_href: []const u8,
    patches: usize,
    patches_href: []const u8,
    files_href: []const u8,
    commits_href: []const u8,
    ci: ?ci_view.Summary = null,
};

const ListRow = struct {
    repo: []const u8,
    repo_avatar: theme.vin.Str,
    repo_href: []const u8,
    title: []const u8,
    href: []const u8,
    labels: []const []const u8 = &.{},
    detail: []const u8 = "",
    status: []const u8 = "",
    ball: []const u8 = "open",
    first_of_repo: bool = false,
    ci: ?ci_view.Summary = null,
};

const StackRow = struct {
    title: []const u8,
    href: []const u8,
    status: []const u8,
    ball: []const u8,
    members: usize,
    conflicted: []const u8,
    ci: ?ci_view.Summary = null,
};

pub fn page(c: Ctx, w: *std.Io.Writer, data: *const Workspace) !void {
    const aa = c.aa();
    var repos: std.ArrayList(RepoRow) = .empty;
    for (data.repos) |repo| try repos.append(aa, try repoRow(c, repo));

    var issues: usize = 0;
    var patches: usize = 0;
    for (data.repos) |repo| {
        issues += repo.open_issues;
        patches += repo.open_patches;
    }

    const view_name: []const u8 = switch (data.view) {
        .home => "home",
        .issues => "issues",
        .patches => "patches",
        .stacks, .stack => "stacks",
    };
    const tasks = try aa.dupe(theme.Link, &.{
        .{ .label = "Repositories", .href = "/", .icon = "hdd-stack", .active = data.view == .home, .count = data.repos.len },
        .{ .label = "Issues", .href = "/home/issues", .icon = "record-circle", .active = data.view == .issues, .count = if (issues > 0) issues else null },
        .{ .label = "Patches", .href = "/home/patches", .icon = "file-diff", .active = data.view == .patches, .count = if (patches > 0) patches else null },
        .{ .label = "Stacks", .href = "/home/stacks", .icon = "stack", .active = data.view == .stacks or data.view == .stack },
    });
    var task_list: std.ArrayList(theme.Link) = .fromOwnedSlice(tasks);
    if (data.events_identity) |identity| {
        try task_list.append(aa, .{ .label = "Workspace discussions", .href = try c.routeUrl(ui.RoutablePage.repoDiscussionsRoute(identity, "")), .icon = "chat-left-text" });
    }

    // the repos source list, as idlci's build history
    var rows: std.ArrayList(theme.Row) = .empty;
    for (repos.items) |repo| try rows.append(aa, .{
        .label = repo.name,
        .href = repo.href,
        .ball = repo.ball,
        .avatar = try c.repoAvatar(repo.icon_name, "cpull-identicon-sm"),
        .title = try c.print("{s}; {d} open issues, {d} open patches", .{ repo.state, repo.issues, repo.patches }),
        .detail = if (repo.issues + repo.patches > 0) try c.print("{d} open", .{repo.issues + repo.patches}) else "",
    });
    const groups = try aa.dupe(theme.Group, &.{.{ .title = "Repositories", .rows = rows.items, .empty = "No repos in the pullfile." }});

    const title: []const u8 = switch (data.view) {
        .home => "Repositories",
        .issues => "Issues",
        .patches => "Patches",
        .stacks => "Stacks",
        .stack => if (data.stack) |s| s.title else "Stack",
    };
    var crumbs: std.ArrayList(theme.Link) = .empty;
    switch (data.view) {
        .home => {},
        .stack => {
            try crumbs.append(aa, .{ .label = "Stacks", .href = "/home/stacks" });
            try crumbs.append(aa, .{ .label = title });
        },
        else => try crumbs.append(aa, .{ .label = title }),
    }
    const chrome: fe.Chrome = .{ .title = try c.print("{s} · {s}", .{ title, data.name }), .crumbs = crumbs.items, .nav = view_name, .tasks = task_list.items, .groups = groups };

    if (data.view == .stack) return stack(c, w, chrome, data);

    var list: std.ArrayList(ListRow) = .empty;
    var previous: ?[]const u8 = null;
    switch (data.view) {
        .issues => for (data.issues) |issue| {
            try list.append(aa, .{
                .repo = issue.repo,
                .repo_avatar = try c.repoAvatar(issue.identity, "cpull-identicon-sm"),
                .repo_href = try c.print("/{s}/issues", .{issue.identity}),
                .title = issue.title,
                .href = issue.url,
                .labels = try ctx.labels(c, issue.labels),
                .first_of_repo = previous == null or !std.mem.eql(u8, previous.?, issue.repo),
            });
            previous = issue.repo;
        },
        .patches => for (data.patches) |patch| {
            try list.append(aa, .{
                .repo = patch.repo,
                .repo_avatar = try c.repoAvatar(patch.identity, "cpull-identicon-sm"),
                .repo_href = try c.print("/{s}/patches", .{patch.identity}),
                .title = patch.title,
                .href = patch.url,
                .detail = try c.print("{s} → {s}", .{ patch.source_branch, patch.target_branch }),
                .status = patch.status,
                .ball = patch.status,
                .first_of_repo = previous == null or !std.mem.eql(u8, previous.?, patch.repo),
                .ci = ci_view.patchBall(c.tools, patch.repo, patch.id),
            });
            previous = patch.repo;
        },
        else => {},
    }
    var stacks: std.ArrayList(StackRow) = .empty;
    for (data.stacks) |s| try stacks.append(aa, .{
        .title = s.title,
        .href = s.url,
        .status = s.status,
        .ball = if (s.conflicted_fields.len > 0) "conflict" else s.status,
        .members = s.members,
        .conflicted = s.conflicted_fields,
        .ci = ci_view.stackBall(c.tools, s.id),
    });

    try fe.emit(c, w, chrome, "workspace.html", .{
        .has_ci = ci_view.enabled(c.tools),
        .view = view_name,
        .name = data.name,
        .events_identity = data.events_identity,
        .repos = repos.items,
        .list = list.items,
        .stacks = stacks.items,
        .tabs = try aa.dupe(theme.Link, &.{
            .{ .label = "Repositories", .href = "/", .active = data.view == .home, .count = data.repos.len },
            // each view loads only its own list, so the others count from the repos
            .{ .label = "Issues", .href = "/home/issues", .active = data.view == .issues, .count = issues },
            .{ .label = "Patches", .href = "/home/patches", .active = data.view == .patches, .count = patches },
            .{ .label = "Stacks", .href = "/home/stacks", .active = data.view == .stacks, .count = if (data.view == .stacks) data.stacks.len else null },
        }),
    });
}

fn repoRow(c: Ctx, repo: Workspace.RepoRow) !RepoRow {
    const off_branch = if (repo.head_branch) |b| !std.mem.eql(u8, b, repo.branch) else true;
    const ball: []const u8, const state: []const u8 = if (!repo.cloned)
        .{ "none", "not cloned" }
    else if (repo.ahead or off_branch)
        .{ "ahead", if (off_branch) "checked out off its pullfile branch" else "head moved past its pin" }
    else if (repo.pin == null)
        .{ "closed", "unpinned" }
    else
        .{ "clean", "at its pin" };
    return .{
        .name = repo.name,
        .avatar = try c.repoAvatar(repo.identity, "cpull-identicon-md"),
        .icon_name = repo.identity,
        .href = try c.print("/{s}", .{repo.identity}),
        .group = repo.group orelse "",
        .ball = ball,
        .state = state,
        .cloned = repo.cloned,
        .branch = repo.branch,
        .head_branch = repo.head_branch orelse "(detached)",
        .head = if (repo.head) |h| ctx.short(h) else "",
        .pin = if (repo.pin) |p| ctx.short(p) else "",
        .off_branch = off_branch,
        .issues = repo.open_issues,
        .issues_href = try c.print("/{s}/issues", .{repo.identity}),
        .patches = repo.open_patches,
        .patches_href = try c.print("/{s}/patches", .{repo.identity}),
        .files_href = try c.print("/{s}", .{repo.identity}),
        .commits_href = try c.print("/{s}/commits", .{repo.identity}),
        .ci = ci_view.repoStatus(c.tools, repo.name),
    };
}

const Member = struct {
    repo: []const u8,
    repo_avatar: theme.vin.Str,
    repo_href: []const u8,
    title: []const u8,
    href: []const u8,
    source_branch: []const u8,
    target_branch: []const u8,
    status: []const u8,
    ball: []const u8,
    mergeable: []const u8,
    target_oid: []const u8,
    pin: []const u8,
    pin_differs: bool,
    ci: ?ci_view.Summary = null,
};

fn stack(c: Ctx, w: *std.Io.Writer, chrome: fe.Chrome, data: *const Workspace) !void {
    const aa = c.aa();
    const s = data.stack orelse return fe.emit(c, w, chrome, "message.html", .{
        .title = "No such stack",
        .text = "There is no stack with this id in the workspace.",
        .links = &[_]theme.Link{.{ .label = "All stacks", .href = "/home/stacks" }},
    });
    var members: std.ArrayList(Member) = .empty;
    for (s.members) |m| {
        const target = m.target_oid orelse "";
        try members.append(aa, .{
            .repo = m.repo,
            .repo_avatar = try c.repoAvatar(m.identity orelse m.repo, "cpull-identicon-sm"),
            .repo_href = if (m.identity) |id| try c.print("/{s}", .{id}) else "",
            .title = if (m.title.len > 0) m.title else ctx.short(m.patch_id),
            .href = m.url orelse "",
            .source_branch = m.source_branch,
            .target_branch = m.target_branch,
            .status = m.status,
            .ball = mergeBall(m.mergeable),
            .mergeable = m.mergeable,
            .target_oid = ctx.short(target),
            .pin = if (m.pin) |p| ctx.short(p) else "",
            .pin_differs = if (m.pin) |p| m.target_oid != null and !std.mem.eql(u8, p, target) else false,
            .ci = ci_view.patchBall(c.tools, m.repo, m.patch_id),
        });
    }
    const open = std.mem.eql(u8, s.status, "open");
    const stack_url = try Workspace.stackUrl(aa, s.id);
    const ci = ci_view.stackCi(c.tools, s.id, stack_url);
    try fe.emit(c, w, chrome, "stack.html", .{
        .ci = ci,
        // the merge gate refuses: the form offers merging anyway
        .gate_blocks = if (ci) |x| x.required and !x.gate_ok else false,
        .title = s.title,
        .status = s.status,
        .ball = if (s.conflicted_fields.len > 0) "conflict" else s.status,
        .labels = try ctx.labels(c, s.labels),
        .author = s.author_email orelse "",
        .conflicted = s.conflicted_fields,
        .description = try markdown.render(aa, ci_view.linkStackMarkdown(c.tools, s.description)),
        .has_description = s.description.len > 0,
        .members = members.items,
        .open = open,
        .mergeable = s.mergeable,
        .merge_action = try c.print("{s}/merge", .{stack_url}),
    });
}

fn mergeBall(mergeable: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "fast_forward", "clean" }, .{ "clean", "clean" },   .{ "nothing", "clean" },
        .{ "merged", "merged" },      .{ "conflict", "conflict" },
    };
    for (map) |entry| if (std.mem.eql(u8, entry[0], mergeable)) return entry[1];
    return "warning";
}
