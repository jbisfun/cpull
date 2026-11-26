//! A themed-page layer for the workspace's Zig tools: the jbisfun wiki theme
//! (Bootstrap from the CDN + the wiki's style.css, icons and light/dark
//! script) in a Jenkins-style layout (global bar, breadcrumb strip,
//! source-list sidebar with <h1> groups, content sheet), the same markup as
//! idlci. Templates are Jinja, rendered with zig-vin.
//!
//! Self-contained: it depends only on std and vin, so it can move into its own
//! package. A tool serves `assets` under "/assets/", writes its page templates
//! as `{% extends "theme/layout.html" %}` with a `content` block, and renders
//! them with `render`, passing a `Layout` as `layout` plus its own data.
const std = @import("std");
pub const vin = @import("vin");

pub const Asset = struct {
    // the request path without its leading slash, e.g. "assets/style.css"
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
};

// the theme's static files, served at "/" ++ path
pub const assets = [_]Asset{
    .{ .path = "assets/style.css", .content_type = "text/css; charset=utf-8", .body = @embedFile("assets/style.css") },
    .{ .path = "assets/icons/favicon.ico", .content_type = "image/x-icon", .body = @embedFile("assets/icons/favicon.ico") },
    .{ .path = "assets/icons/favicon.svg", .content_type = "image/svg+xml", .body = @embedFile("assets/icons/favicon.svg") },
    .{ .path = "assets/icons/icon-64.png", .content_type = "image/png", .body = @embedFile("assets/icons/icon-64.png") },
};

pub const Template = vin.MapLoader.Entry;

// the theme's own templates; an app's templates import or extend them by name
pub const templates = [_]Template{
    .{ .name = "theme/layout.html", .source = @embedFile("templates/layout.html") },
    .{ .name = "theme/macros.html", .source = @embedFile("templates/macros.html") },
};

// a link in the global bar, the crumbs, the sidebar tasks or a tab strip
pub const Link = struct {
    label: []const u8,
    // empty for a crumb that isn't a link
    href: []const u8 = "",
    active: bool = false,
    // a Bootstrap Icons name, without "bi-"
    icon: []const u8 = "",
    count: ?usize = null,
    title: []const u8 = "",
};

// a row of a sidebar group
pub const Row = struct {
    label: []const u8,
    href: []const u8,
    // right-aligned small text
    detail: []const u8 = "",
    icon: []const u8 = "",
    // a status ball's status (see .ball-* in style.css), drawn instead of the icon
    ball: []const u8 = "",
    active: bool = false,
    title: []const u8 = "",
};

// a sidebar group under an <h1> heading, like idlci's Build Queue
pub const Group = struct {
    title: []const u8,
    rows: []const Row = &.{},
    // shown when there are no rows
    empty: []const u8 = "Nothing here.",
    more_href: []const u8 = "",
    more_label: []const u8 = "all",
};

pub const Badge = struct {
    label: []const u8,
    icon: []const u8 = "",
    title: []const u8 = "",
};

pub const Search = struct {
    action: []const u8,
    method: []const u8 = "get",
    name: []const u8 = "q",
    placeholder: []const u8 = "Search",
    value: []const u8 = "",
};

pub const Flash = struct {
    text: []const u8,
    // a Bootstrap alert kind: secondary (the wiki's yellow note), danger, ...
    kind: []const u8 = "secondary",
};

// the page chrome, passed to templates as `layout`
pub const Layout = struct {
    title: []const u8,
    // the brand in the global bar
    site: []const u8,
    brand_href: []const u8 = "/",
    // where `assets` are served
    assets: []const u8 = "/assets",
    nav: []const Link = &.{},
    badges: []const Badge = &.{},
    search: ?Search = null,
    // the first crumb is the home page; the last is the current page
    crumbs: []const Link = &.{},
    tasks: []const Link = &.{},
    groups: []const Group = &.{},
    flashes: []const Flash = &.{},
    footer: []const Link = &.{},
    // extra stylesheets after the theme's, for the app's own rules
    stylesheets: []const []const u8 = &.{},
};

// a relative time with its exact UTC form, for the `time` macro
pub const Time = struct {
    relative: []const u8,
    exact: []const u8 = "",
};

// html the template must not escape (rendered markdown, prebuilt fragments)
pub fn markup(html: []const u8) vin.Str {
    return .{ .bytes = html, .safe = true };
}

// renders template `name` from the theme's and `app` templates with `context`
// (a struct, converted with vin.valueFrom; give it a `layout: Layout` field
// for pages that extend theme/layout.html) to `writer`. a template error is
// logged with vin's diagnostic and returned.
pub fn render(
    comptime app: []const Template,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    name: []const u8,
    context: anytype,
    writer: *std.Io.Writer,
) !void {
    const entries = comptime templates ++ app[0..app.len].*;
    var map: vin.MapLoader = .{ .entries = &entries };
    var env = try vin.Environment.initWithLoader(gpa, .{
        .autoescape = true,
        .trim_blocks = true,
        .lstrip_blocks = true,
    }, map.loader());
    defer env.deinit();
    var diag: vin.Diagnostic = .{};
    env.withDiag(&diag);
    const value = try vin.valueFrom(arena, context);
    var template = env.getTemplate(name) catch |err| {
        std.log.err("theme: can't load {s}: {s}: {f}", .{ name, @errorName(err), diag });
        return err;
    };
    defer template.deinit();
    template.withDiag(&diag);
    template.renderTo(writer, value) catch |err| {
        std.log.err("theme: can't render {s}: {s}: {f}", .{ name, @errorName(err), diag });
        return err;
    };
}

test "a page extending the layout renders the chrome and escapes data" {
    const app = [_]Template{.{ .name = "page.html", .source = "{% extends \"theme/layout.html\" %}{% block content %}<p>{{ text }}</p>{% endblock %}" }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&app, std.testing.allocator, arena.allocator(), "page.html", .{
        .layout = Layout{
            .title = "t",
            .site = "tool",
            .nav = &.{.{ .label = "Home", .href = "/", .active = true }},
            .crumbs = &.{ .{ .label = "Home", .href = "/" }, .{ .label = "Page" } },
            .groups = &.{.{ .title = "Group", .rows = &.{.{ .label = "row", .href = "/r", .ball = "open" }} }},
        },
        .text = "<b>",
    }, &out.writer);
    const html = out.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "wiki-globalnav") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>&lt;b&gt;</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "ball-open") != null);
}
