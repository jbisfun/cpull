// cpull's themed web frontend: every page server-rendered in the jbisfun wiki
// theme with idlci's Jenkins layout, through cpull's `Frontend` hook
// (web.zig). The page data comes from cpull's snapshot (ui.Page and
// ui.Session.Data); the views in this dir turn it into template data, and the
// templates in templates/ extend theme/layout.html. Forms post to the same
// urls web.zig handles for cpull's own UI, so writes work without the wasm
// client. src/main.zig declares `cpull_frontend` from here; build with
// `-Dfrontend=classic` to get cpull's own terminal-grid web UI back.
const std = @import("std");
const ui = @import("../../ui.zig");
const web = @import("../../web.zig");
const theme = @import("../theme/theme.zig");
const Ctx = @import("ctx.zig").Ctx;
const workspace_views = @import("views/workspace.zig");
const repo_views = @import("views/repo.zig");
const site_views = @import("views/site.zig");
const fork_views = @import("views/fork.zig");
const highlight = @import("../../wiki/highlight.zig");

pub const site_name = "cpull";

pub const frontend: web.Frontend = .{
    .files = &files,
    .renderHtml = render,
    .site_name = site_name,
};

// the theme's assets plus cpull's own stylesheet; index.html leaves the whole
// document to renderHtml, which writes the theme layout
const files = blk: {
    var list: [theme.assets.len + 2]web.Embed = undefined;
    list[0] = .{ .path = "index.html", .content_type = "text/html; charset=utf-8", .body = "{{{ CPULL_HTML }}}" };
    // the wiki highlighter's token colours follow cpull's rules (file view)
    list[1] = .{ .path = "assets/cpull.css", .content_type = "text/css; charset=utf-8", .body = @embedFile("cpull.css") ++ highlight.css };
    for (theme.assets, 2..) |asset, i| list[i] = .{ .path = asset.path, .content_type = asset.content_type, .body = asset.body };
    break :blk list;
};

pub const templates = [_]theme.Template{
    .{ .name = "macros.html", .source = @embedFile("templates/macros.html") },
    .{ .name = "report.html", .source = @embedFile("templates/report.html") },
    .{ .name = "workspace.html", .source = @embedFile("templates/workspace.html") },
    .{ .name = "stack.html", .source = @embedFile("templates/stack.html") },
    .{ .name = "files.html", .source = @embedFile("templates/files.html") },
    .{ .name = "commits.html", .source = @embedFile("templates/commits.html") },
    .{ .name = "commit.html", .source = @embedFile("templates/commit.html") },
    .{ .name = "diff.html", .source = @embedFile("templates/diff.html") },
    .{ .name = "events.html", .source = @embedFile("templates/events.html") },
    .{ .name = "refs.html", .source = @embedFile("templates/refs.html") },
    .{ .name = "threads.html", .source = @embedFile("templates/threads.html") },
    .{ .name = "thread.html", .source = @embedFile("templates/thread.html") },
    .{ .name = "thread_form.html", .source = @embedFile("templates/thread_form.html") },
    .{ .name = "message.html", .source = @embedFile("templates/message.html") },
    .{ .name = "about.html", .source = @embedFile("templates/about.html") },
    .{ .name = "user.html", .source = @embedFile("templates/user.html") },
    .{ .name = "resolve.html", .source = @embedFile("templates/resolve.html") },
    .{ .name = "confirm.html", .source = @embedFile("templates/confirm.html") },
    .{ .name = "settings.html", .source = @embedFile("templates/settings.html") },
    .{ .name = "undo.html", .source = @embedFile("templates/undo.html") },
    .{ .name = "delete.html", .source = @embedFile("templates/delete.html") },
};

// cpull's renderHtml hook: the whole document for one page
pub fn render(allocator: std.mem.Allocator, page: *const ui.Page, session: *const ui.Session.Data, writer: *std.Io.Writer) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const c: Ctx = .{ .gpa = allocator, .arena = &arena, .session = session };
    switch (page.*) {
        .workspace => |*data| try workspace_views.page(c, writer, data),
        .repo => |*data| try repo_views.page(c, writer, data),
        .home => |*data| try site_views.home(c, writer, data),
        .user => |*data| try site_views.user(c, writer, data),
        .fork => |*data| try fork_views.page(c, writer, data),
        .not_found => try site_views.notFound(c, writer),
    }
}

// what a view puts around its content: the title, the crumbs after the home
// crumb, the active global nav item, and the sidebar
pub const Chrome = struct {
    title: []const u8,
    crumbs: []const theme.Link = &.{},
    nav: []const u8 = "",
    tasks: []const theme.Link = &.{},
    groups: []const theme.Group = &.{},
    // an svg favicon url, e.g. a repo's identicon
    icon: []const u8 = "",
};

// renders `template` with the page's layout and `data` as `page`
pub fn emit(c: Ctx, w: *std.Io.Writer, chrome: Chrome, template: []const u8, data: anytype) !void {
    const layout = try buildLayout(c, chrome);
    try theme.render(&templates, c.gpa, c.aa(), template, .{ .layout = layout, .page = data }, w);
}

// the workspace server's global bar, shared with the features mounted beside
// haxy's pages (src/ci); `active` names the current item
pub fn workspaceNav(aa: std.mem.Allocator, active: []const u8) ![]const theme.Link {
    const items = [_]struct { label: []const u8, href: []const u8, key: []const u8 }{
        .{ .label = "Repositories", .href = "/", .key = "home" },
        .{ .label = "Issues", .href = "/home/issues", .key = "issues" },
        .{ .label = "Patches", .href = "/home/patches", .key = "patches" },
        .{ .label = "Stacks", .href = "/home/stacks", .key = "stacks" },
        .{ .label = "CI", .href = "/ci", .key = "ci" },
        .{ .label = "Wiki", .href = "/wiki/", .key = "wiki" },
    };
    const out = try aa.alloc(theme.Link, items.len);
    for (items, out) |item, *link| link.* = .{ .label = item.label, .href = item.href, .active = std.mem.eql(u8, item.key, active) };
    return out;
}

fn buildLayout(c: Ctx, chrome: Chrome) !theme.Layout {
    const aa = c.aa();
    var nav: std.ArrayList(theme.Link) = .empty;
    var badges: std.ArrayList(theme.Badge) = .empty;
    var crumbs: std.ArrayList(theme.Link) = .empty;
    var footer: std.ArrayList(theme.Link) = .empty;
    var flashes: std.ArrayList(theme.Flash) = .empty;

    if (c.workspace()) |name| {
        try nav.appendSlice(aa, try workspaceNav(aa, chrome.nav));
        try badges.append(aa, .{ .label = name, .icon = "boxes", .title = "pull workspace" });
        try crumbs.append(aa, .{ .label = name, .href = "/" });
        try footer.append(aa, .{ .label = try c.print("pull workspace {s}", .{name}) });
    } else switch (c.session.host_kind) {
        .local => {
            try nav.append(aa, .{ .label = "Repository", .href = "/", .active = true });
            try badges.append(aa, .{ .label = "local", .icon = "laptop", .title = "local mode" });
            try crumbs.append(aa, .{ .label = "Repository", .href = "/" });
        },
        .server => {
            try nav.append(aa, .{ .label = "Home", .href = "/", .active = std.mem.eql(u8, chrome.nav, "home") });
            try nav.append(aa, .{ .label = "Users", .href = try c.url(.{ .home_users = .{} }), .active = std.mem.eql(u8, chrome.nav, "users") });
            try crumbs.append(aa, .{ .label = "Home", .href = "/" });
            if (c.session.user_name) |name| try badges.append(aa, .{ .label = name, .icon = "person" });
        },
    }
    try crumbs.appendSlice(aa, chrome.crumbs);
    try footer.append(aa, .{ .label = "cpull" });
    try footer.append(aa, .{ .label = if (c.server()) "server" else "local mode" });

    if (c.session.workspace_flash) |text| try flashes.append(aa, .{ .text = text });
    if (c.session.sync_failure) |text| try flashes.append(aa, .{ .text = try c.print("The last sync failed: {s}", .{text}), .kind = "danger" });
    if (c.session.undo_failure) |text| try flashes.append(aa, .{ .text = try c.print("The last undo failed: {s}", .{text}), .kind = "danger" });

    return .{
        .title = try c.print("{s} · {s}", .{ chrome.title, site_name }),
        .site = site_name,
        .nav = nav.items,
        .badges = badges.items,
        .crumbs = crumbs.items,
        .tasks = chrome.tasks,
        .groups = chrome.groups,
        .flashes = flashes.items,
        .footer = footer.items,
        .stylesheets = &.{"/assets/cpull.css"},
        .icon = chrome.icon,
    };
}

test "every cpull template parses" {
    try theme.parseAll(&templates, std.testing.allocator);
}
