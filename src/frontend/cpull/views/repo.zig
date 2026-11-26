// a repo's pages (ui/Repo.zig): its tabs become the sidebar tasks, its
// branches and tags sidebar groups, and the current tab the content.
const std = @import("std");
const ui = @import("../../../ui.zig");
const evt = @import("../../../event.zig");
const theme = @import("../../theme/theme.zig");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const markdown = @import("../markdown.zig");
const report_views = @import("report.zig");
const report_anchor = @import("../../../report/anchor.zig");
const threads = @import("threads.zig");
const admin_views = @import("admin.zig");
const fork_views = @import("fork.zig");
const Ctx = ctx.Ctx;
const Repo = ui.Repo;
const RoutablePage = ui.RoutablePage;

pub const Tab = enum { files, changes, refs, discussions, issues, patches, events, undo, settings };

// the repo's "owner:name", empty in plain local mode where routes elide it
pub fn identity(data: anytype) []const u8 {
    if (comptime isFork(@TypeOf(data))) return "";
    return switch (data.handle.location) {
        .repo => |value| value,
        .fork => "",
    };
}

// the repo views also draw a fork's tabs (views/fork.zig), which pass a
// *const ui.Fork where a repo page passes its *const Repo
pub fn isFork(comptime T: type) bool {
    return T == *const ui.Fork;
}

// the url prefix the repo's post routes hang off
pub fn base(c: Ctx, data: *const Repo) ![]const u8 {
    const id = identity(data);
    return if (id.len == 0) "" else c.print("/{s}", .{id});
}

fn currentTab(route: RoutablePage) Tab {
    return switch (route) {
        .repo_files => .files,
        .repo_commits, .repo_diff => .changes,
        .repo_refs => .refs,
        .repo_discussions => .discussions,
        .repo_issues => .issues,
        .repo_patches => .patches,
        .repo_events => .events,
        .repo_undo => .undo,
        else => .settings,
    };
}

fn shown(data: *const Repo, tab: Tab) bool {
    return switch (tab) {
        .files, .changes, .refs => true,
        .discussions => data.repo.event.discuss_role != null,
        .issues => data.repo.event.issue_role != null,
        .patches => data.repo.event.patch_role != null,
        .events => data.handle.canWrite(),
        .undo => data.undo != null,
        .settings => data.settings != null,
    };
}

// a tab's url: the current route when it is selected, else the tab's own route
pub fn tabHref(c: Ctx, data: *const Repo, tab: Tab) ![]const u8 {
    if (currentTab(c.session.current_page) == tab) return c.url(c.session.current_page);
    const id = identity(data);
    const header = &data.header;
    return switch (tab) {
        .files => try c.routeUrl(data.files.filesRoute("", 0)),
        .changes => switch (data.changes) {
            .diff => |*d| try c.routeUrl(d.route.page(d.window.start, d.path)),
            .commits => |*cm| try c.routeUrl(RoutablePage.repoCommitsRoute(id, header.ref_or_oid, header.ref_or_oid_value, cm.base_oid)),
        },
        .refs => try c.routeUrl(RoutablePage.repoRefsRoute(id, .branch, "")),
        .discussions => try c.url(try ui.widget.thread.searchRoute(RoutablePage.repoDiscussionsRoute(id, ""), header.discussions_search)),
        .issues => try c.url(try ui.widget.thread.searchRoute(RoutablePage.repoIssuesRoute(id, .open, ""), header.issues_search)),
        .patches => try c.url(try ui.widget.thread.searchRoute(RoutablePage.repoPatchesRoute(id, .open, ""), header.patches_search)),
        .events => try c.routeUrl(RoutablePage.repoEventsRoute(id, .active, null, "", null)),
        .undo => try c.routeUrl(RoutablePage.repoUndoRoute(id, null)),
        .settings => try c.routeUrl(RoutablePage.repoSettingsRoute(id)),
    };
}

fn tabLabel(data: *const Repo, tab: Tab) []const u8 {
    return switch (tab) {
        .files => "Files",
        .changes => if (data.changes == .diff) "Diff" else "Commits",
        .refs => "Branches & Tags",
        .discussions => "Discussions",
        .issues => "Issues",
        .patches => "Patches",
        .events => "Events",
        .undo => "Undo",
        .settings => "Settings",
    };
}

fn tabIcon(tab: Tab) []const u8 {
    return switch (tab) {
        .files => "folder2-open",
        .changes => "clock-history",
        .refs => "signpost-split",
        .discussions => "chat-left-text",
        .issues => "record-circle",
        .patches => "file-diff",
        .events => "journal-text",
        .undo => "arrow-counterclockwise",
        .settings => "gear",
    };
}

fn openCount(data: *const Repo, tab: Tab) ?usize {
    const count = switch (tab) {
        .issues => data.issues.window(.open).count,
        .patches => data.patches.window(.open).count,
        .changes => if (data.changes == .commits) (data.changes.commits.commit_count orelse return null) else return null,
        else => return null,
    };
    return if (count > 0) @intCast(count) else null;
}

// the sidebar and crumbs every repo page shares; `extra` crumbs follow the tab's
pub fn chrome(c: Ctx, data: anytype, title: []const u8, extra: []const theme.Link) !fe.Chrome {
    if (comptime isFork(@TypeOf(data))) return fork_views.chrome(c, data, title, extra);
    const aa = c.aa();
    const current = currentTab(c.session.current_page);
    var tasks: std.ArrayList(theme.Link) = .empty;
    for (std.enums.values(Tab)) |tab| {
        if (!shown(data, tab)) continue;
        try tasks.append(aa, .{ .label = tabLabel(data, tab), .href = try tabHref(c, data, tab), .icon = tabIcon(tab), .active = tab == current, .count = openCount(data, tab) });
    }
    const id = identity(data);
    if (data.repo.event.issue_role != null and data.issues.viewer != null) try tasks.append(aa, .{ .label = "New issue", .href = try c.routeUrl(RoutablePage.repoThreadNewRoute(.issue, id)), .icon = "plus-square" });
    if (data.repo.event.patch_role != null and data.patches.viewer != null) try tasks.append(aa, .{ .label = "New patch", .href = try c.routeUrl(RoutablePage.repoThreadNewRoute(.patch, id)), .icon = "plus-square" });

    // workspace mode: the workspace's repos, like the workspace pages' sidebar
    // (the branch picker over the files and commits takes the refs); else the
    // branches, then tags, as source-list groups
    var groups: std.ArrayList(theme.Group) = .empty;
    if (c.session.workspace_repos.len > 0) {
        var rows: std.ArrayList(theme.Row) = .empty;
        for (c.session.workspace_repos) |repo| try rows.append(aa, .{
            .label = repo.name,
            .href = try c.print("/{s}", .{repo.identity}),
            .avatar = try c.repoAvatar(repo.identity, "cpull-identicon-sm"),
            .active = std.mem.eql(u8, repo.identity, id),
        });
        try groups.append(aa, .{ .title = "Repositories", .rows = rows.items, .more_href = "/", .more_label = "all" });
    } else for ([_]RoutablePage.RefOrOid{ .branch, .tag }) |kind| {
        const column = if (kind == .branch) &data.refs.branches else &data.refs.tags;
        if (kind == .tag and column.names.len == 0) continue;
        var rows: std.ArrayList(theme.Row) = .empty;
        for (column.names) |name| {
            const encoded = try ui.urlEncodeRef(aa, name);
            const active = data.files.patchrev_id == null and data.files.ref_or_oid == kind and std.mem.eql(u8, data.files.ref_or_oid_value, encoded) and (current == .files or current == .changes);
            try rows.append(aa, .{
                .label = name,
                .href = try c.routeUrl(RoutablePage.repoFilesRoute(id, kind, encoded, "", 0)),
                .icon = if (kind == .branch) "git" else "tag",
                .active = active,
            });
        }
        try groups.append(aa, .{
            .title = if (kind == .branch) "Branches" else "Tags",
            .rows = rows.items,
            .empty = "None yet.",
            .more_href = if (column.next != null) try tabHref(c, data, .refs) else "",
        });
    }

    var crumbs: std.ArrayList(theme.Link) = .empty;
    const name = if (data.header.owner_name.len > 0 and c.workspace() == null) try c.print("{s}:{s}", .{ data.header.owner_name, data.header.name }) else data.header.name;
    try crumbs.append(aa, .{ .label = name, .href = try c.routeUrl(RoutablePage.repoFilesRoute(id, null, "", "", 0)), .avatar = try c.repoAvatar(data.header.name, "cpull-identicon-sm") });
    try crumbs.append(aa, .{ .label = tabLabel(data, current), .href = try tabHref(c, data, current) });
    try crumbs.appendSlice(aa, extra);
    return .{
        .title = try c.print("{s} · {s}", .{ title, name }),
        .crumbs = crumbs.items,
        .nav = if (c.workspace() != null) "home" else "",
        .tasks = tasks.items,
        .groups = groups.items,
        .icon = try iconUrl(c, data),
    };
}

// the repo's identicon as a file (web.zig serves /<repo>/icon.svg), for the
// favicon; plain local mode's repo is "/", a fork page has none
fn iconUrl(c: Ctx, data: *const Repo) ![]const u8 {
    const id = identity(data);
    if (id.len > 0) return c.print("/{s}/icon.svg", .{id});
    return if (c.workspace() == null and !c.server() and data.handle.location == .repo) "/icon.svg" else "";
}

pub fn page(c: Ctx, w: *std.Io.Writer, data: *const Repo) !void {
    switch (currentTab(c.session.current_page)) {
        .files => try files(c, w, data),
        .changes => switch (data.changes) {
            .commits => |*cm| if (cm.message and cm.commits.len > 0) try commit(c, w, data, cm, &cm.commits[0]) else try commits(c, w, data, cm),
            .diff => |*d| try diff(c, w, data, d),
        },
        .refs => try refs(c, w, data),
        .issues => try threads.panel(c, w, data, .issue, &data.issues),
        .patches => try threads.panel(c, w, data, .patch, &data.patches),
        .discussions => try threads.panel(c, w, data, .discuss, &data.discussions),
        .events => try events(c, w, data),
        .undo => try admin_views.undo(c, w, data),
        .settings => try admin_views.settings(c, w, data),
    }
}

// --- files ---------------------------------------------------------------

const max_markdown_lines = 2000;

// the branch/tag picker over the files and commits views: a Bootstrap
// dropdown of the repo's branches and tags (the refs tab's first window)
const PickerItem = struct { label: []const u8, href: []const u8, active: bool };
const PickerGroup = struct { title: []const u8, icon: []const u8, items: []const PickerItem };
const Picker = struct {
    kind: []const u8,
    name: []const u8,
    groups: []const PickerGroup,
    more_href: []const u8,
    more: bool,
};

fn refPicker(c: Ctx, data: *const Repo, kind_label: []const u8, name: []const u8, current_kind: ?RoutablePage.RefOrOid, current_value: []const u8, comptime target: enum { files, commits }) !Picker {
    const aa = c.aa();
    const id = identity(data);
    var groups: std.ArrayList(PickerGroup) = .empty;
    for ([_]RoutablePage.RefOrOid{ .branch, .tag }) |kind| {
        const column = if (kind == .branch) &data.refs.branches else &data.refs.tags;
        var items: std.ArrayList(PickerItem) = .empty;
        for (column.names) |ref_name| {
            const encoded = try ui.urlEncodeRef(aa, ref_name);
            try items.append(aa, .{
                .label = ref_name,
                .href = switch (target) {
                    .files => try c.routeUrl(RoutablePage.repoFilesRoute(id, kind, encoded, "", 0)),
                    .commits => try c.routeUrl(RoutablePage.repoCommitsRoute(id, kind, encoded, "")),
                },
                .active = current_kind == kind and std.mem.eql(u8, encoded, current_value),
            });
        }
        try groups.append(aa, .{ .title = if (kind == .branch) "Branches" else "Tags", .icon = if (kind == .branch) "git" else "tag", .items = items.items });
    }
    return .{
        .kind = kind_label,
        .name = name,
        .groups = groups.items,
        .more_href = try c.routeUrl(RoutablePage.repoRefsRoute(id, .branch, "")),
        .more = data.refs.branches.next != null or data.refs.tags.next != null,
    };
}

// syntax highlighting for the files view: the wiki's tree-sitter highlighter
// (src/wiki/highlight.zig) over the shown lines, split back into one html
// fragment per line. only the languages it has a grammar for, and not for
// huge windows.
const highlight = @import("../../../wiki/highlight.zig");
const highlight_max_bytes = 1 << 20;

fn highlightLanguage(name: []const u8) ?[]const u8 {
    const extension = std.Io.Dir.path.extension(name);
    if (extension.len < 2) return null;
    const known = [_][]const u8{ "sh", "bash", "zsh", "json", "rs", "py", "js", "mjs", "cjs", "jsx", "yaml", "yml", "toml", "zig", "zon", "lua", "diff", "patch" };
    for (known) |k| if (std.ascii.eqlIgnoreCase(extension[1..], k)) return k;
    return null;
}

fn highlightLines(aa: std.mem.Allocator, lang: []const u8, lines: []const []const u8) !?[]const []const u8 {
    var total: usize = 0;
    for (lines) |line| total += line.len + 1;
    if (total > highlight_max_bytes) return null;
    var out: std.ArrayList(u8) = .empty;
    highlight.write(aa, &out, lang, try std.mem.join(aa, "\n", lines)) catch return null;
    const split = try splitHighlighted(aa, out.items);
    // the highlighter keeps every byte, so the line counts agree
    if (split.len < lines.len) return null;
    return split[0..lines.len];
}

// highlighted html cut at its newlines, closing the spans open at each line's
// end and opening them again on the next line. the highlighter writes only
// `<span class="...">`, `</span>` and escaped text.
pub fn splitHighlighted(aa: std.mem.Allocator, html: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var open: std.ArrayList([]const u8) = .empty;
    var line: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "</span>")) {
            _ = open.pop();
            try line.appendSlice(aa, "</span>");
            i += "</span>".len;
        } else if (std.mem.startsWith(u8, html[i..], "<span")) {
            const end = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len - 1) + 1;
            try open.append(aa, html[i..end]);
            try line.appendSlice(aa, html[i..end]);
            i = end;
        } else if (html[i] == '\n') {
            for (open.items) |_| try line.appendSlice(aa, "</span>");
            try result.append(aa, try line.toOwnedSlice(aa));
            for (open.items) |tag| try line.appendSlice(aa, tag);
            i += 1;
        } else {
            const next = std.mem.indexOfAnyPos(u8, html, i, "<\n") orelse html.len;
            try line.appendSlice(aa, html[i..next]);
            i = next;
        }
    }
    try result.append(aa, try line.toOwnedSlice(aa));
    return result.items;
}

test splitHighlighted {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try splitHighlighted(arena.allocator(), "<span class=\"a\">x\n<span class=\"b\">y</span>\nz</span>");
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("<span class=\"a\">x</span>", lines[0]);
    try std.testing.expectEqualStrings("<span class=\"a\"><span class=\"b\">y</span></span>", lines[1]);
    try std.testing.expectEqualStrings("<span class=\"a\">z</span>", lines[2]);
}

const Entry = struct { name: []const u8, href: []const u8, dir: bool, path: []const u8 = "" };
const Line = struct {
    number: usize,
    text: []const u8,
    // the highlighted line, when the language has a grammar
    html: theme.vin.Str = theme.markup(""),
    reports: []const report_views.Marker = &.{},
};
const Body = struct {
    kind: []const u8, // markdown, code, binary, empty, unloaded
    html: theme.vin.Str = theme.markup(""),
    lines: []const Line = &.{},
    note: []const u8 = "",
    first_href: []const u8 = "",
    next_href: []const u8 = "",
    open_href: []const u8 = "",
    // cpull: the open reports (anchored issues) on this file
    reports: []const report_views.Marker = &.{},
    highlighted: bool = false,
    // the "report this line" form (local and workspace mode)
    report: ?ReportForm = null,
};

// what the files view's report form posts to web.zig's `report` route: the
// file and the ref it shows; the line, title and note come from the reader
const ReportForm = struct { action: []const u8, file: []const u8, ref: []const u8, value: []const u8 };

fn reportForm(c: Ctx, f: *const Repo.Files, path: []const u8) !?ReportForm {
    if (c.server() or f.patchrev_id != null) return null;
    const id = switch (f.handle.location) {
        .repo => |value| value,
        .fork => return null,
    };
    return .{
        .action = if (id.len == 0) "/report" else try c.print("/{s}/report", .{id}),
        .file = path,
        .ref = @tagName(f.ref_or_oid),
        .value = f.ref_or_oid_value,
    };
}

pub fn files(c: Ctx, w: *std.Io.Writer, data: anytype) !void {
    const is_fork = comptime isFork(@TypeOf(data));
    const aa = c.aa();
    const f = &data.files;
    const id = identity(data);
    const selected = selectedEntry(f);

    // the path from the root, each directory a link
    var path_crumbs: std.ArrayList(theme.Link) = .empty;
    const path = if (selected) |entry| try Repo.Files.childDir(aa, f.dir, entry.name) else f.dir;
    try path_crumbs.append(aa, .{ .label = data.header.name, .href = try c.routeUrl(plainRoute(f, "")) });
    if (path.len > 0) {
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            const end = segments.index orelse {
                try path_crumbs.append(aa, .{ .label = segment });
                break;
            };
            try path_crumbs.append(aa, .{ .label = segment, .href = try c.routeUrl(plainRoute(f, path[0 .. end - 1])) });
        }
    }

    const ref_kind: []const u8, const ref_name: []const u8 = if (f.patchrev_id) |patchrev|
        .{ "Patch revision", ctx.short(patchrev) }
    else switch (f.ref_or_oid) {
        .branch => .{ "Branch", try c.decode(f.ref_or_oid_value) },
        .tag => .{ "Tag", try c.decode(f.ref_or_oid_value) },
        .object => .{ "Commit", ctx.short(f.ref_or_oid_value) },
    };

    var entries: std.ArrayList(Entry) = .empty;
    var readme: ?Body = null;
    var readme_name: []const u8 = "";
    var body: ?Body = null;
    if (selected) |entry| {
        body = try fileBody(c, f, path, entry, try c.routeUrl(f.filesRoute(path, 0)));
    } else {
        if (f.dir.len != 0) {
            const parent = if (std.mem.lastIndexOfScalar(u8, f.dir, '/')) |slash| f.dir[0..slash] else "";
            try entries.append(aa, .{ .name = "..", .href = try c.routeUrl(f.filesRoute(parent, 0)), .dir = true });
        }
        for (f.entries) |entry| {
            const child = try Repo.Files.childDir(aa, f.dir, entry.name);
            const slash = if (f.find != null) std.mem.lastIndexOfScalar(u8, entry.name, '/') else null;
            try entries.append(aa, .{
                .name = if (slash) |s| entry.name[s + 1 ..] else entry.name,
                .path = if (slash) |s| entry.name[0..s] else "",
                .href = try c.routeUrl(f.filesRoute(child, 0)),
                .dir = entry.is_dir,
            });
        }
        if (f.find == null) for (f.entries) |*entry| {
            if (entry.is_dir or !isReadme(entry.name)) continue;
            const child = try Repo.Files.childDir(aa, f.dir, entry.name);
            readme = try fileBody(c, f, child, entry, try c.routeUrl(f.filesRoute(child, 0)));
            readme_name = entry.name;
            break;
        };
    }

    const sync_status: ?[]const u8 = if (is_fork) null else data.events.header.sync_status;
    const title = if (path.len > 0) path else data.header.name;
    try fe.emit(c, w, try chrome(c, data, title, &.{}), "files.html", .{
        .name = data.header.name,
        .avatar = try c.repoAvatar(data.header.name, "cpull-identicon-lg"),
        .description = if (is_fork) "" else data.repo.event.description,
        .no_commits = f.no_commits,
        .ref_kind = ref_kind,
        .ref_name = ref_name,
        .picker = if (is_fork) null else try refPicker(c, data, ref_kind, ref_name, if (f.patchrev_id != null) null else f.ref_or_oid, f.ref_or_oid_value, .files),
        .default_href = if (explicitRef(c.session.current_page)) try c.routeUrl(RoutablePage.repoFilesRoute(id, null, "", "", 0)) else "",
        .history_href = if (f.patchrev_id == null) try c.routeUrl(f.handle.location.commitsRoute(f.ref_or_oid, f.ref_or_oid_value, "")) else "",
        .path = path_crumbs.items,
        .find_action = if (f.find_available) try c.print("{s}/search", .{try c.routeUrl(f.handle.location.filesRoute(f.ref_or_oid, f.ref_or_oid_value, "", 0))}) else "",
        .find = f.find orelse "",
        .find_clear = if (f.find != null) try c.routeUrl(plainRoute(f, "")) else "",
        .entries = entries.items,
        .capped = f.capped,
        .file = if (selected) |entry| std.Io.Dir.path.basenamePosix(entry.name) else "",
        .body = body,
        .readme = readme,
        .readme_name = readme_name,
        .sync_status = sync_status orelse "",
        .sync_action = if (sync_status != null) (if (is_fork) "" else try c.print("{s}/sync", .{try base(c, data)})) else "",
        .clone = if (is_fork) &[_]Command{} else try cloneCommands(c, data),
    });
}

const Command = struct { label: []const u8, text: []const u8 };

// the clone commands cpull offers for the repo (server mode)
fn cloneCommands(c: Ctx, data: *const Repo) ![]const Command {
    const id = identity(data);
    var list: std.ArrayList(Command) = .empty;
    if (data.handle.read_access == .public) if (c.session.git_http_url) |url| try list.append(c.aa(), .{ .label = "HTTP", .text = try c.print("git clone {s}/{s}", .{ url, id }) });
    if (c.session.git_ssh_url) |url| try list.append(c.aa(), .{ .label = "SSH", .text = try c.print("{s}git clone {s}/{s}", .{ c.session.git_ssh_prefix, url, id }) });
    return list.items;
}

// whether the route names a ref, rather than reading the default branch
fn explicitRef(route: RoutablePage) bool {
    return switch (route) {
        .repo_files => |*f| f.ref_kind != null or f.patchrev_id.len != 0,
        .repo_commits => |*cm| cm.ref_or_oid != null or cm.merge.len != 0,
        .repo_diff => |*d| d.ref_or_oid != null or d.patchrev_id.len != 0,
        else => false,
    };
}

fn selectedEntry(f: *const Repo.Files) ?*const Repo.Files.Entry {
    const name = f.selected_file orelse return null;
    for (f.entries) |*entry| {
        if (!entry.is_dir and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn plainRoute(f: *const Repo.Files, path: []const u8) ?RoutablePage {
    if (f.patchrev_id != null) return f.filesRoute(path, 0);
    return f.handle.location.filesRoute(f.ref_or_oid, f.ref_or_oid_value, path, 0);
}

fn fileBody(c: Ctx, f: *const Repo.Files, path: []const u8, entry: *const Repo.Files.Entry, file_url: []const u8) !Body {
    const aa = c.aa();
    if (!entry.loaded) return .{ .kind = "unloaded", .open_href = try c.routeUrl(f.filesRoute(path, 0)) };
    if (entry.is_binary) return .{ .kind = "binary" };
    const first = entry.window_start == 0 and !entry.has_more;
    if (entry.lines.len == 0 and first) return .{ .kind = "empty" };
    const reports = try report_views.markers(c, switch (f.handle.location) {
        .repo => |id| id,
        .fork => "",
    }, f.anchors, path, entry.lines, entry.window_start);
    if (isMarkdown(entry.name) and first and entry.lines.len <= max_markdown_lines) {
        return .{ .kind = "markdown", .html = try markdown.render(aa, try std.mem.join(aa, "\n", entry.lines)), .reports = reports, .report = try reportForm(c, f, path) };
    }
    var lines = try aa.alloc(Line, entry.lines.len);
    const highlighted = if (highlightLanguage(entry.name)) |lang| try highlightLines(aa, lang, entry.lines) else null;
    for (entry.lines, 0..) |line, i| lines[i] = .{
        .number = entry.window_start + i + 1,
        .text = line,
        .html = if (highlighted) |h| theme.markup(h[i]) else theme.markup(""),
        .reports = try report_views.onLine(c, reports, entry.window_start + i + 1),
    };
    return .{
        .kind = "code",
        .highlighted = highlighted != null,
        .report = try reportForm(c, f, path),
        .reports = reports,
        .lines = lines,
        .open_href = file_url,
        .note = if (first) "" else try c.print("Showing lines {d}–{d}.", .{ entry.window_start + 1, entry.window_start + entry.lines.len }),
        .first_href = if (entry.window_start > 0) try c.routeUrl(f.filesRoute(path, 0)) else "",
        .next_href = if (entry.has_more) try c.routeUrl(f.filesRoute(path, entry.window_start + entry.lines.len + 1)) else "",
    };
}

fn isMarkdown(name: []const u8) bool {
    const extension = std.Io.Dir.path.extension(name);
    return std.ascii.eqlIgnoreCase(extension, ".md") or std.ascii.eqlIgnoreCase(extension, ".markdown");
}

fn isReadme(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "README") or std.ascii.eqlIgnoreCase(name, "README.md");
}

// --- commits -------------------------------------------------------------

const CommitRow = struct {
    oid: []const u8,
    summary: []const u8,
    href: []const u8,
    author: ctx.Person,
    time: theme.Time,
    merge: bool,
    stats: []const u8,
    diff_href: []const u8,
    files_href: []const u8,
};

fn commitStats(c: Ctx, stats_maybe: anytype) ![]const u8 {
    const stats = stats_maybe orelse return "";
    var out: std.Io.Writer.Allocating = .init(c.aa());
    const parts = [_]struct { u64, []const u8, []const u8 }{
        .{ stats.lines_added, "+", "" },
        .{ stats.lines_removed, "−", "" },
        .{ stats.files_changed + stats.files_added + stats.files_removed, "", " files" },
    };
    var first = true;
    for (parts) |part| {
        const count, const prefix, const suffix = part;
        if (count == 0) continue;
        if (!first) try out.writer.writeAll(" ");
        first = false;
        try out.writer.print("{s}{d}{s}", .{ prefix, count, suffix });
    }
    return out.written();
}

pub fn commits(c: Ctx, w: *std.Io.Writer, data: anytype, cm: *const Repo.Commits) !void {
    const aa = c.aa();
    const location = cm.handle.location;
    var rows: std.ArrayList(CommitRow) = .empty;
    for (cm.commits) |*commit_item| try rows.append(aa, .{
        .oid = ctx.short(commit_item.oid),
        .summary = ctx.summary(commit_item.message),
        .href = try c.routeUrl(location.commitMessageRoute(.object, commit_item.oid, cm.base_oid)),
        .author = try c.author(commit_item.author),
        .time = try c.time(commit_item.timestamp),
        .merge = commit_item.merge,
        .stats = try commitStats(c, commit_item.stats),
        .diff_href = try c.routeUrl(location.commitDiffRoute(commit_item.oid, commit_item.parent_oid, cm.path)),
        .files_href = try c.routeUrl(location.filesRoute(.object, commit_item.oid, "", 0)),
    });
    const ref_kind: []const u8, const ref_name: []const u8 = switch (cm.ref_or_oid) {
        .branch => .{ "Branch", try c.decode(cm.ref_or_oid_value) },
        .tag => .{ "Tag", try c.decode(cm.ref_or_oid_value) },
        .object => .{ "Commit", ctx.short(cm.ref_or_oid_value) },
    };
    const next = if (cm.next_start) |oid| try c.routeUrl(pageRoute(cm, oid)) else "";
    try fe.emit(c, w, try chrome(c, data, "Commits", &.{}), "commits.html", .{
        .no_commits = cm.no_commits,
        .ref_kind = ref_kind,
        .ref_name = ref_name,
        .picker = if (comptime isFork(@TypeOf(data))) null else try refPicker(c, data, ref_kind, ref_name, cm.ref_or_oid, cm.ref_or_oid_value, .commits),
        .path = cm.path,
        .count = cm.commit_count,
        .rows = rows.items,
        .search_action = if (cm.search_available) try c.print("{s}/search", .{try c.routeUrl(searchRoute(cm))}) else "",
        .search = cm.search orelse "",
        .clear_href = if (cm.search != null) try c.routeUrl(searchRoute(cm)) else "",
        .files_href = try c.routeUrl(location.filesRoute(cm.ref_or_oid, cm.ref_or_oid_value, "", 0)),
        .next = next,
    });
}

fn searchRoute(cm: *const Repo.Commits) ?RoutablePage {
    if (cm.default_branch.len != 0) return cm.handle.location.commitsRoute(.branch, cm.default_branch, "");
    return cm.handle.location.commitsRoute(cm.ref_or_oid, cm.ref_or_oid_value, cm.base_oid);
}

fn pageRoute(cm: *const Repo.Commits, oid: []const u8) ?RoutablePage {
    if (cm.handle.location != .repo or cm.ref_or_oid == .object) return cm.handle.location.commitsRoute(.object, oid, cm.base_oid);
    const route = cm.handle.location.commitsRoute(cm.ref_or_oid, cm.ref_or_oid_value, cm.base_oid) orelse return null;
    const paged = route.withFrom(oid) orelse return null;
    return paged.withSearch(cm.search orelse return paged);
}

pub fn commit(c: Ctx, w: *std.Io.Writer, data: anytype, cm: *const Repo.Commits, item: *const Repo.Commits.Commit) !void {
    const location = cm.handle.location;
    const root = std.mem.allEqual(u8, item.parent_oid, '0');
    try fe.emit(c, w, try chrome(c, data, ctx.summary(item.message), &.{.{ .label = ctx.short(item.oid) }}), "commit.html", .{
        .summary = ctx.summary(item.message),
        .message = item.message,
        .truncated = item.message_truncated,
        .oid = item.oid,
        .author = try c.author(item.author),
        .committer = if (item.committer != .unknown) try c.author(item.committer) else null,
        .time = try c.time(item.timestamp),
        .merge = item.merge,
        .parent = if (root) "" else ctx.short(item.parent_oid),
        .parent_href = if (root) "" else try c.routeUrl(location.commitMessageRoute(.object, item.parent_oid, cm.base_oid)),
        .stats = try commitStats(c, item.stats),
        .history_href = try c.routeUrl(location.commitsRoute(.object, item.oid, cm.base_oid)),
        .diff_href = try c.routeUrl(location.commitDiffRoute(item.oid, item.parent_oid, cm.path)),
        .files_href = try c.routeUrl(location.filesRoute(.object, item.oid, "", 0)),
        .merge_href = if (item.merge) if (location.commitsMergeRoute(item.oid)) |route| try c.url(route) else "" else "",
    });
}

// --- diff ----------------------------------------------------------------

const DiffLine = struct { number: []const u8, sign: []const u8, text: []const u8, class: []const u8, reports: []const report_views.Marker = &.{} };

// flag the diff lines open reports point at: on the new side (kept and added
// lines), the line holding the report's text nearest its line number, else
// the line with its number
fn diffMarkers(c: Ctx, identity_value: []const u8, anchors: []const report_anchor.FileAnchor, path: []const u8, lines: []DiffLine) !void {
    if (identity_value.len == 0) return;
    for (anchors) |a| {
        if (!std.mem.eql(u8, a.file, path)) continue;
        const want = std.mem.trim(u8, a.line_text, " \t\r");
        var best: ?usize = null;
        var best_distance: u64 = std.math.maxInt(u64);
        for (lines, 0..) |line, i| {
            if (line.sign[0] == '-') continue;
            const number = std.fmt.parseInt(u64, line.number, 10) catch continue;
            const distance = if (number > a.line) number - a.line else a.line - number;
            const same_text = want.len > 0 and std.mem.eql(u8, std.mem.trim(u8, line.text, " \t\r"), want);
            if (same_text and distance <= 200 and distance < best_distance) {
                best = i;
                best_distance = distance;
            } else if (best == null and distance == 0) best = i;
        }
        const i = best orelse continue;
        const marker: report_views.Marker = .{
            .line = std.fmt.parseInt(u64, lines[i].number, 10) catch a.line,
            .title = a.title,
            .href = try c.routeUrl(RoutablePage.repoThreadCommentsRoute(.issue, identity_value, a.id, 0)),
            .short_id = a.id[0..8],
        };
        lines[i].reports = try std.mem.concat(c.aa(), report_views.Marker, &.{ lines[i].reports, &.{marker} });
    }
}
const DiffFile = struct {
    path: []const u8,
    status: []const u8,
    file_href: []const u8,
    only_href: []const u8,
    note: []const u8,
    hunks: []const []const DiffLine,
};

pub fn diff(c: Ctx, w: *std.Io.Writer, data: anytype, d: *const Repo.Diff) !void {
    const aa = c.aa();
    const hunks = d.window.hunks;
    var diff_files: std.ArrayList(DiffFile) = .empty;
    var i: usize = 0;
    while (i < hunks.len) {
        var end = i + 1;
        while (end < hunks.len and hunks[end].path == null) end += 1;
        const group = hunks[i..end];
        const first = group[0];
        const path = first.path orelse d.path;
        var tables: std.ArrayList([]const DiffLine) = .empty;
        if (first.status == .changed) for (group) |*hunk| {
            var lines: std.ArrayList(DiffLine) = .empty;
            var it = std.mem.splitScalar(u8, hunk.text, '\n');
            for (hunk.prefixes) |prefix| {
                const line = it.next() orelse break;
                const rest = std.mem.trimStart(u8, line, " ");
                const digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
                const text = if (digits + 2 <= rest.len) rest[digits + 2 ..] else "";
                try lines.append(aa, .{
                    .number = rest[0..digits],
                    .sign = try aa.dupe(u8, &.{prefix}),
                    .text = text,
                    .class = switch (prefix) {
                        '+' => "add",
                        '-' => "del",
                        else => "",
                    },
                });
            }
            try diffMarkers(c, identity(data), data.files.anchors, path, lines.items);
            try tables.append(aa, lines.items);
        };
        try diff_files.append(aa, .{
            .path = path,
            .status = @tagName(first.status),
            .file_href = try c.routeUrl(diffFileRoute(d.route, path, first.status)),
            .only_href = if (d.path.len == 0 and first.status == .changed) try c.routeUrl(d.route.page(0, path)) else "",
            .note = switch (first.status) {
                .added => "A new file; open it to read it.",
                .removed => "The file was removed; open it to read what it held.",
                .binary => "Binary file not shown.",
                .changed => "",
            },
            .hunks = tables.items,
        });
        i = end;
    }

    var heading: []const u8 = "Changes";
    var compared: []const u8 = "";
    var compared_href: []const u8 = "";
    var commit_href: []const u8 = "";
    var files_href: []const u8 = "";
    switch (d.route) {
        .repo => |r| {
            heading = if (r.ref_or_oid == .object) try c.print("Changes in commit {s}", .{ctx.short(r.value)}) else try c.print("Changes at {s}", .{try c.decode(r.value)});
            if (!std.mem.allEqual(u8, r.base_oid, '0')) {
                compared = ctx.short(r.base_oid);
                compared_href = try c.routeUrl(RoutablePage.repoCommitMessageRoute(r.identity, .object, r.base_oid, ""));
            }
            commit_href = try c.routeUrl(RoutablePage.repoCommitMessageRoute(r.identity, r.ref_or_oid, r.value, ""));
            files_href = try c.routeUrl(RoutablePage.repoFilesRoute(r.identity, r.ref_or_oid, r.value, "", 0));
        },
        .patchrev => |r| {
            heading = try c.print("Changes in patch revision {s}", .{ctx.short(r.id)});
            files_href = try c.routeUrl(RoutablePage.repoPatchRevFilesRoute(r.identity, r.id, "", 0));
        },
        .fork => {},
    }
    const empty: []const u8 = if (hunks.len > 0) "" else if (d.window.truncated) "These changes are too large to show." else if (d.window.start > 0) "No more changes." else if (d.path.len != 0) "No changes to this file." else "No changes.";
    try fe.emit(c, w, try chrome(c, data, heading, &.{}), "diff.html", .{
        .heading = heading,
        .compared = compared,
        .compared_href = compared_href,
        .commit_href = commit_href,
        .files_href = files_href,
        .path = d.path,
        .all_href = if (d.path.len != 0) try c.routeUrl(d.route.page(0, "")) else "",
        .files = diff_files.items,
        .empty = empty,
        .truncated = d.window.truncated and hunks.len > 0,
        .prev = if (d.window.start > 0) try c.routeUrl(d.route.page(d.window.start -| Repo.Diff.page_size, d.path)) else "",
        .next = if (d.window.has_more) try c.routeUrl(d.route.page(d.window.start + hunks.len, d.path)) else "",
    });
}

fn diffFileRoute(route: Repo.Diff.Route, path: []const u8, status: Repo.Diff.Status) ?RoutablePage {
    if (status == .removed) return switch (route) {
        .repo => |r| RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
        .patchrev => |r| RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
        .fork => |f| RoutablePage.forkFilesRoute(f.identity, f.id, if (f.base_oid.len != 0) f.base_oid else f.patch_base_oid, path, 0),
    };
    return switch (route) {
        .repo => |r| RoutablePage.repoFilesRoute(r.identity, r.ref_or_oid, r.value, path, 0),
        .patchrev => |r| RoutablePage.repoPatchRevFilesRoute(r.identity, r.id, path, 0),
        .fork => |f| RoutablePage.forkFilesRoute(f.identity, f.id, f.oid, path, 0),
    };
}

// --- refs ----------------------------------------------------------------

const RefColumn = struct {
    title: []const u8,
    icon: []const u8,
    rows: []const theme.Row,
    empty: []const u8,
    prev: []const u8,
    next: []const u8,
};

fn refs(c: Ctx, w: *std.Io.Writer, data: *const Repo) !void {
    const aa = c.aa();
    const r = &data.refs;
    const id = identity(data);
    var columns: std.ArrayList(RefColumn) = .empty;
    for ([_]RoutablePage.RefKind{ .branch, .tag }) |kind| {
        const column = if (kind == .branch) &r.branches else &r.tags;
        var rows: std.ArrayList(theme.Row) = .empty;
        for (column.names) |name| try rows.append(aa, .{
            .label = name,
            .href = try c.routeUrl(RoutablePage.repoFilesRoute(id, if (kind == .branch) .branch else .tag, try ui.urlEncodeRef(aa, name), "", 0)),
            .icon = if (kind == .branch) "git" else "tag",
        });
        try columns.append(aa, .{
            .title = if (kind == .branch) "Branches" else "Tags",
            .icon = if (kind == .branch) "git" else "tag",
            .rows = rows.items,
            .empty = if (r.search != null) "No names match the search." else if (kind == .branch) "No branches yet." else "No tags yet.",
            .prev = if (column.prev) |from| try refWindow(c, id, kind, from, r.search) else "",
            .next = if (column.next) |from| try refWindow(c, id, kind, from, r.search) else "",
        });
    }
    try fe.emit(c, w, try chrome(c, data, "Branches & Tags", &.{}), "refs.html", .{
        .search_action = try c.print("{s}/search", .{try c.routeUrl(RoutablePage.repoRefsRoute(id, .branch, ""))}),
        .search = r.search orelse "",
        .columns = columns.items,
    });
}

fn refWindow(c: Ctx, id: []const u8, kind: RoutablePage.RefKind, from: []const u8, search: ?[]const u8) ![]const u8 {
    const route = RoutablePage.repoRefsRoute(id, kind, try ui.urlEncodeRef(c.aa(), from)) orelse return error.RouteTooLong;
    return c.routeUrl(route.withSearch(search orelse ""));
}

// --- events --------------------------------------------------------------

const EventRow = struct { kind: []const u8, id: []const u8, author: ctx.Person, href: []const u8, selected: bool };

fn kindLabel(kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .user => "User",
        .repo => "Repository",
        .fork => "Fork",
        .grant => "Grant",
        .notify => "Notification",
        .discuss => "Discussion",
        .issue => "Issue",
        .comment => "Comment",
        .attach => "Attachment",
        .assign => "Assignment",
        .patchrev => "Patch revision",
        .patch => "Patch",
        else => "Event",
    };
}

fn events(c: Ctx, w: *std.Io.Writer, data: *const Repo) !void {
    const aa = c.aa();
    const e = &data.events;
    const win = switch (e.view) {
        .active => &e.active,
        .removed => &e.removed,
    };
    var rows: std.ArrayList(EventRow) = .empty;
    for (win.events) |*item| try rows.append(aa, .{
        .kind = kindLabel(item.kind),
        .id = ctx.short(item.id),
        .author = try c.author(item.author),
        .href = item.view_url orelse "",
        .selected = if (e.selected) |s| std.mem.eql(u8, s.id, item.id) else false,
    });
    try fe.emit(c, w, try chrome(c, data, "Events", &.{}), "events.html", .{
        .sync_status = e.header.sync_status orelse "",
        .sync_action = if (e.header.sync_status != null) try c.print("{s}/sync", .{try base(c, data)}) else "",
        .moment = e.moment,
        .all_href = try c.routeUrl(RoutablePage.repoEventsRoute(e.identity, .active, null, "", null)),
        .tabs = try aa.dupe(theme.Link, &.{
            .{ .label = "Active", .href = try c.routeUrl(RoutablePage.repoEventsRoute(e.identity, .active, null, "", e.moment)), .active = e.view == .active, .count = e.active.count },
            .{ .label = "Removed", .href = try c.routeUrl(RoutablePage.repoEventsRoute(e.identity, .removed, null, "", e.moment)), .active = e.view == .removed, .count = e.removed.count },
        }),
        .rows = rows.items,
        .first = if (e.selected != null) try c.routeUrl(RoutablePage.repoEventsRoute(e.identity, e.view, null, "", e.moment)) else "",
        .next = if (win.next) |n| try c.routeUrl(RoutablePage.repoEventsRoute(e.identity, e.view, n.kind, n.id, e.moment)) else "",
    });
}
