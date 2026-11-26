// a fork's pages (ui/Fork.zig, server mode): the fork a fork-backed patch
// lives in, with its patch, diff, files and commits tabs plus the forker's
// delete tab. The tabs reuse the repo views (repo.zig takes a *const ui.Fork
// where it takes a repo) and the thread view for the patch.
const std = @import("std");
const ui = @import("../../../ui.zig");
const theme = @import("../../theme/theme.zig");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const repo_views = @import("repo.zig");
const threads = @import("threads.zig");
const Ctx = ctx.Ctx;
const RoutablePage = ui.RoutablePage;
const Fork = ui.Fork;

const Tab = enum { patch, diff, files, commits, delete };

fn currentTab(route: RoutablePage) Tab {
    return switch (route) {
        .fork_diff => .diff,
        .fork_files => .files,
        .fork_commits => .commits,
        .fork_delete => .delete,
        else => .patch,
    };
}

// "forker:name", the fork's url identity
fn forkIdentity(c: Ctx, data: *const Fork) ![]const u8 {
    return c.print("{s}:{s}", .{ data.header.forker_name, data.header.name });
}

fn tabHref(c: Ctx, data: *const Fork, tab: Tab) ![]const u8 {
    if (currentTab(c.session.current_page) == tab) return c.url(c.session.current_page);
    const id = try forkIdentity(c, data);
    const fork_id = data.header.id;
    return c.routeUrl(switch (tab) {
        .patch => RoutablePage.forkPatchRoute(id, fork_id),
        .diff => RoutablePage.forkDiffRoute(id, fork_id, "", "", 0, ""),
        .files => RoutablePage.forkFilesRoute(id, fork_id, "", "", 0),
        .commits => RoutablePage.forkCommitsRoute(id, fork_id, ""),
        .delete => RoutablePage.forkDeleteRoute(id, fork_id),
    });
}

pub fn chrome(c: Ctx, data: *const Fork, title: []const u8, extra: []const theme.Link) !fe.Chrome {
    const aa = c.aa();
    const current = currentTab(c.session.current_page);
    const labels = [_][]const u8{ "Patch", "Diff", "Files", "Commits", "Delete fork" };
    const icons = [_][]const u8{ "file-diff", "file-earmark-diff", "folder2-open", "clock-history", "trash" };
    var tasks: std.ArrayList(theme.Link) = .empty;
    for (std.enums.values(Tab), labels, icons) |tab, label, icon| {
        if (tab == .delete and data.delete == null) continue;
        try tasks.append(aa, .{
            .label = label,
            .href = try tabHref(c, data, tab),
            .icon = icon,
            .active = tab == current,
            .count = if (tab == .commits) (if (data.commits.commit_count) |n| (if (n > 0) @as(?usize, @intCast(n)) else null) else null) else null,
        });
    }

    // the target repo, then the fork itself
    const target = data.patch.identity;
    var crumbs: std.ArrayList(theme.Link) = .empty;
    try crumbs.append(aa, .{ .label = target, .href = try c.routeUrl(RoutablePage.repoFilesRoute(target, null, "", "", 0)), .avatar = try c.repoAvatar(target, "cpull-identicon-sm") });
    try crumbs.append(aa, .{ .label = try c.print("fork by {s}", .{data.header.forker_name}), .href = try tabHref(c, data, .patch) });
    try crumbs.append(aa, .{ .label = labels[@intFromEnum(current)], .href = try tabHref(c, data, current) });
    try crumbs.appendSlice(aa, extra);

    const groups = try aa.dupe(theme.Group, &.{.{
        .title = "Fork",
        .rows = try aa.dupe(theme.Row, &.{
            .{ .label = target, .href = try c.routeUrl(RoutablePage.repoPatchesRoute(target, .open, "")), .icon = "box-arrow-up-right", .title = "The repository this fork proposes changes to" },
            .{ .label = data.header.forker_name, .href = try c.userUrl(data.header.forker_name), .icon = "person", .title = "Who made the fork" },
        }),
    }});
    return .{
        .title = try c.print("{s} · fork of {s}", .{ title, target }),
        .crumbs = crumbs.items,
        .tasks = tasks.items,
        .groups = groups,
        .icon = try c.print("/{s}/icon.svg", .{target}),
    };
}

pub fn page(c: Ctx, w: *std.Io.Writer, data: *const Fork) !void {
    switch (currentTab(c.session.current_page)) {
        .patch => {
            const entry = data.patch.selectedThread() orelse return threads.notFound(c, w, data, .patch, &data.patch);
            try threads.detail(c, w, data, .patch, &data.patch, entry);
        },
        .diff => try repo_views.diff(c, w, data, &data.diff),
        .files => try repo_views.files(c, w, data),
        .commits => if (data.commits.message and data.commits.commits.len > 0)
            try repo_views.commit(c, w, data, &data.commits, &data.commits.commits[0])
        else
            try repo_views.commits(c, w, data, &data.commits),
        .delete => try delete(c, w, data),
    }
}

fn delete(c: Ctx, w: *std.Io.Writer, data: *const Fork) !void {
    const target = (data.delete orelse return error.NotFound).target;
    var typed: []const u8 = "";
    var error_text: []const u8 = "";
    if (c.feedback(.delete)) |f| if (f.target == .fork) {
        typed = f.confirm;
        error_text = switch (f.failure) {
            .wrong_confirm => "What you typed doesn't match the fork's name.",
            .wrong_password => "That isn't your password.",
        };
    };
    try fe.emit(c, w, try chrome(c, data, "Delete fork", &.{}), "delete.html", .{
        .noun = "fork",
        .text = "Deleting the fork removes its branch, and with it the patch it backs.",
        .action = try c.print("{s}/delete", .{try c.url(c.session.current_page)}),
        .confirm_text = target.confirmText(),
        .typed = typed,
        .error_text = error_text,
    });
}
