// the pages outside repos and workspaces: the server's about page and user
// list, a user's repos, and the not-found page. account pages (login,
// signup, keys, settings) are deliberately not rendered: accounts are going
// away in workspace mode, so those routes show a pointer to the terminal UI.
const std = @import("std");
const ui = @import("../../../ui.zig");
const evt = @import("../../../event.zig");
const theme = @import("../../theme/theme.zig");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const markdown = @import("../markdown.zig");
const Ctx = ctx.Ctx;

fn accountRoute(route: ui.RoutablePage) bool {
    return switch (route) {
        .home_user, .user_user, .repo_user, .fork_user, .home_repo_new, .user_repo_new, .repo_repo_new, .fork_repo_new, .home_user_new, .user_user_new, .repo_user_new, .fork_user_new => true,
        else => false,
    };
}

fn account(c: Ctx, w: *std.Io.Writer, chrome: fe.Chrome) !void {
    try fe.emit(c, w, chrome, "message.html", .{
        .title = "Not in the web UI",
        .text = "Accounts, keys and new repositories are managed from cpull's terminal UI (ssh into the server), not this web UI.",
        .links = &[_]theme.Link{.{ .label = "Home", .href = "/" }},
    });
}

pub fn home(c: Ctx, w: *std.Io.Writer, data: *const ui.Home) !void {
    const route = c.session.current_page;
    const users_view = route == .home_users;
    const chrome: fe.Chrome = .{
        .title = if (users_view) "Users" else "Home",
        .crumbs = if (users_view) &.{.{ .label = "Users" }} else &.{},
        .nav = if (users_view) "users" else "home",
        .tasks = &.{
            .{ .label = "About", .href = "/", .icon = "house", .active = !users_view },
            .{ .label = "Users", .href = try c.url(.{ .home_users = .{} }), .icon = "people", .active = users_view },
        },
    };
    if (accountRoute(route)) return account(c, w, chrome);
    if (users_view) {
        const u = &data.users;
        const aa = c.aa();
        var rows: std.ArrayList(theme.Row) = .empty;
        for (u.users) |entry| try rows.append(aa, .{ .label = entry.name, .href = try c.userUrl(entry.name), .icon = "person" });
        const search = u.search orelse "";
        return fe.emit(c, w, chrome, "user.html", .{
            .title = "Users",
            .description = "",
            .search_action = try c.print("{s}/search", .{try c.url(.{ .home_users = .{} })}),
            .search = search,
            .rows = rows.items,
            .empty = if (u.start > 0) "No more users." else if (u.search != null) "No users match this search." else "Nobody has registered on this server.",
            .prev = if (u.start > 0) try usersUrl(c, u.start -| ui.Home.Users.page_size, search) else "",
            .next = if (u.next_start) |start| try usersUrl(c, start, search) else "",
            .forks = &[_]theme.Row{},
            .show_forks = false,
        });
    }
    const about = &data.about;
    try fe.emit(c, w, chrome, "about.html", .{
        .title = about.title orelse "cpull",
        .text = try markdown.render(c.aa(), about.text),
        .has_text = std.mem.trim(u8, about.text, " \t\r\n").len > 0,
    });
}

fn usersUrl(c: Ctx, start: usize, search: []const u8) ![]const u8 {
    const route: ui.RoutablePage = .{ .home_users = .{ .start = start } };
    return c.routeUrl(route.withSearch(search));
}

pub fn user(c: Ctx, w: *std.Io.Writer, data: *const ui.User) !void {
    const aa = c.aa();
    const name = data.user.name;
    const name_array = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    const chrome: fe.Chrome = .{
        .title = name,
        .crumbs = try aa.dupe(theme.Link, &.{ .{ .label = "Users", .href = try c.url(.{ .home_users = .{} }) }, .{ .label = name } }),
        .nav = "users",
        .tasks = try aa.dupe(theme.Link, &.{
            .{ .label = "Repositories", .href = try c.url(.{ .user_repos = .{ .name = name_array } }), .icon = "hdd-stack", .active = true },
        }),
    };
    if (accountRoute(c.session.current_page)) return account(c, w, chrome);
    var rows: std.ArrayList(theme.Row) = .empty;
    for (data.repos) |repo| {
        const identity = try c.print("{s}:{s}", .{ name, repo.event.name });
        try rows.append(aa, .{
            .label = repo.event.name,
            .href = try c.routeUrl(ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0)),
            .detail = repo.event.description,
            .icon = if (repo.event.read_access == .private) "lock" else "hdd",
        });
    }
    var forks: std.ArrayList(theme.Row) = .empty;
    for (data.forks) |f| {
        const identity = try c.print("{s}:{s}", .{ name, f.repo_name });
        try forks.append(aa, .{ .label = f.title, .href = try c.routeUrl(ui.RoutablePage.forkPatchRoute(identity, f.id)), .detail = try c.print("a fork of {s}", .{f.repo_name}), .icon = "diagram-2" });
    }
    const search = data.repos_search orelse "";
    try fe.emit(c, w, chrome, "user.html", .{
        .title = name,
        .description = "",
        .search_action = try c.print("{s}/search", .{try c.url(.{ .user_repos = .{ .name = name_array } })}),
        .search = search,
        .rows = rows.items,
        .empty = if (data.repos_start > 0) "No more repositories." else if (data.repos_search != null) "No repositories match this search." else "No repositories you can see.",
        .prev = if (data.repos_start > 0) try reposUrl(c, name_array, data.repos_start -| ui.User.page_size, search) else "",
        .next = if (data.repos_next_start) |start| try reposUrl(c, name_array, start, search) else "",
        .forks = forks.items,
        .show_forks = true,
    });
}

fn reposUrl(c: Ctx, name: ui.RoutablePage.Array(evt.User.name_max_len), start: usize, search: []const u8) ![]const u8 {
    const route: ui.RoutablePage = .{ .user_repos = .{ .name = name, .start = start } };
    return c.routeUrl(route.withSearch(search));
}

// forks only exist on a server; their pages stay in cpull's classic UI
pub fn fork(c: Ctx, w: *std.Io.Writer, data: *const ui.Fork) !void {
    try fe.emit(c, w, .{ .title = data.header.name, .crumbs = &.{.{ .label = data.header.name }} }, "message.html", .{
        .title = "Not in the web UI",
        .text = "Fork pages aren't part of the themed web UI yet. Use cpull's terminal UI, or build cpull with -Dfrontend=classic.",
        .links = &[_]theme.Link{.{ .label = "Home", .href = "/" }},
    });
}

pub fn notFound(c: Ctx, w: *std.Io.Writer) !void {
    try fe.emit(c, w, .{ .title = "Not found", .crumbs = &.{.{ .label = "Not found" }} }, "message.html", .{
        .title = "Page not found",
        .text = "There is no page at this address, or you can't see it.",
        .links = &[_]theme.Link{.{ .label = "Home", .href = "/" }},
    });
}
