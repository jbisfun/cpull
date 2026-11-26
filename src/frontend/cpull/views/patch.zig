// a patch's publish and merge pages. Publishing makes a draft (server mode)
// visible and starts its conversation; merging lands a patch in its target
// branch: on the server as the source commits or one squashed commit, in a
// pull workspace through the workspace's single-patch merge (the way a stack
// merges each member). Both post to web.zig's routes for these pages, like
// the terminal UI's confirmation forms.
const std = @import("std");
const ui = @import("../../../ui.zig");
const pch = @import("../../../patch.zig");
const theme = @import("theme");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const repo_views = @import("repo.zig");
const threads = @import("threads.zig");
const Ctx = ctx.Ctx;
const Repo = ui.Repo;
const Patches = Repo.Patches;

// whether the patch page offers its merge page: Patches.canMerge on the
// server, and in a workspace an open, published, unconflicted branch patch
pub fn mergeOffered(c: Ctx, data: *const Patches, entry: *const Patches.Entry) bool {
    const event = entry.record.event;
    const ready = !entry.draft and !entry.conflicted and event.revision != null and event.status.kind() == .open;
    if (c.server()) return ready and (entry.fork_exists or event.source_branch != null) and data.viewer != null;
    return ready and c.workspace() != null and event.source_branch != null and entry.can_modify;
}

const Button = struct { label: []const u8, action: []const u8, note: []const u8, primary: bool };
const Fact = struct { term: []const u8, value: []const u8 };

pub fn publish(c: Ctx, w: *std.Io.Writer, repo: *const Repo, data: *const Patches) !void {
    const entry = data.selectedThread() orelse return threads.notFound(c, w, repo, .patch, data);
    const thread_url = try threads.threadUrl(c, .patch, data.identity, entry.id);
    const url = try c.routeUrl(Patches.publishRoute(data.identity, entry.id));
    // only the draft's author may publish it, which the publish route checks
    const buttons = if (entry.draft and data.viewer != null) try c.aa().dupe(Button, &.{.{ .label = "Publish patch", .action = url, .note = "", .primary = true }}) else &[_]Button{};
    try confirmPage(c, w, repo, entry, thread_url, "Publish", .{
        .heading = "Publish this draft",
        .icon = "send",
        .text = if (buttons.len > 0) "Publishing shows the patch to everyone who can read the repository and opens its conversation. Pushes to its fork keep updating it." else "This patch isn't a draft, so there is nothing to publish.",
        .facts = try facts(c, entry),
        .buttons = buttons,
    });
}

pub fn merge(c: Ctx, w: *std.Io.Writer, repo: *const Repo, data: *const Patches) !void {
    const entry = data.selectedThread() orelse return threads.notFound(c, w, repo, .patch, data);
    const thread_url = try threads.threadUrl(c, .patch, data.identity, entry.id);
    const url = try c.routeUrl(Patches.mergeRoute(data.identity, entry.id));
    const aa = c.aa();
    var buttons: std.ArrayList(Button) = .empty;
    var text: []const u8 = "";
    if (!mergeOffered(c, data, entry)) {
        text = "This patch can't be merged here: it must be open, published, free of conflicts and up to date with its source.";
    } else if (c.server()) {
        // the server checked both ways of merging
        const m = entry.mergeability;
        text = "Merging moves the target branch to include the patch, marks the patch merged and removes its fork.";
        try buttons.append(aa, .{ .label = "Merge patch", .action = if (m.source == .clean) url else "", .note = statusNote(m.source, "the source commits, as they are"), .primary = true });
        try buttons.append(aa, .{ .label = "Squash and merge", .action = if (m.squash == .clean) try c.print("{s}/squash", .{url}) else "", .note = statusNote(m.squash, "one commit holding every change"), .primary = false });
    } else {
        text = "Merging moves the target branch in the workspace repo to include the source branch (a fast-forward when it can) and marks the patch merged. The work tree isn't touched, so the target must not be checked out.";
        try buttons.append(aa, .{ .label = "Merge patch", .action = url, .note = "the source commits, as they are; a conflict leaves everything as it is", .primary = true });
    }
    try confirmPage(c, w, repo, entry, thread_url, "Merge", .{
        .heading = "Merge this patch",
        .icon = "sign-merge-left",
        .text = text,
        .facts = try facts(c, entry),
        .buttons = buttons.items,
    });
}

fn statusNote(status: pch.Mergeability.Status, what: []const u8) []const u8 {
    return switch (status) {
        .clean => what,
        .conflict => "conflicts with the target branch",
        .unknown => "unavailable: the merge couldn't be checked",
    };
}

fn facts(c: Ctx, entry: *const Patches.Entry) ![]const Fact {
    const aa = c.aa();
    const event = entry.record.event;
    var list: std.ArrayList(Fact) = .empty;
    try list.append(aa, .{ .term = "Source", .value = event.source_branch orelse (if (entry.fork_exists) entry.fork_identity else "a removed fork") });
    try list.append(aa, .{ .term = "Target", .value = event.target_branch });
    if (entry.commit_count) |count| try list.append(aa, .{ .term = "Commits", .value = try c.print("{d}", .{count}) });
    return list.items;
}

fn confirmPage(c: Ctx, w: *std.Io.Writer, repo: *const Repo, entry: *const Patches.Entry, thread_url: []const u8, crumb: []const u8, content: anytype) !void {
    const extra = try c.aa().dupe(theme.Link, &.{ .{ .label = entry.record.event.title, .href = thread_url }, .{ .label = crumb } });
    try fe.emit(c, w, try repo_views.chrome(c, repo, content.heading, extra), "confirm.html", .{
        .heading = content.heading,
        .icon = content.icon,
        .title = entry.record.event.title,
        .back = thread_url,
        .text = content.text,
        .facts = content.facts,
        .buttons = content.buttons,
    });
}
