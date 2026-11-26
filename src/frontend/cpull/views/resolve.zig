// settling a thread's metadata conflict (issues and patches): each conflicted
// field shows both versions, each with a "use this" link that reloads the page
// with that side picked (the route's theirs: list), over a resolution input
// prefilled from the picked side; the description's conflicting hunks the
// same, between the text both sides agree on. One form posts every field to
// web.zig's resolve route, like the terminal UI's resolve form
// (ui/widget/thread.zig initResolveForm).
const std = @import("std");
const ui = @import("../../../ui.zig");
const evt = @import("../../../event.zig");
const theme = @import("../../theme/theme.zig");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const repo_views = @import("repo.zig");
const threads = @import("threads.zig");
const Ctx = ctx.Ctx;
const Repo = ui.Repo;

const Version = struct { label: []const u8, text: []const u8, use_href: []const u8, picked: bool };

// a title/labels conflict (editable) or a status/revision/target conflict
// (atomic: one side or the other)
const Field = struct {
    title: []const u8,
    name: []const u8,
    ours: Version,
    theirs: Version,
    value: []const u8,
    atomic: bool,
};

const Chunk = struct {
    // same: both sides agree; auto: one side changed it; conflict: both did
    kind: []const u8,
    text: []const u8 = "",
    label: []const u8 = "",
    name: []const u8 = "",
    ours: ?Version = null,
    theirs: ?Version = null,
    value: []const u8 = "",
};

pub fn page(c: Ctx, w: *std.Io.Writer, repo: *const Repo, comptime kind: evt.EventKind, data: *const threads.Data(kind)) !void {
    const n = comptime threads.names(kind);
    const entry = data.selectedThread() orelse return threads.notFound(c, w, repo, kind, data);
    const conflict = data.conflict orelse return threads.notFound(c, w, repo, kind, data);
    const aa = c.aa();
    const thread_url = try threads.threadUrl(c, kind, data.identity, entry.id);

    var fields: std.ArrayList(Field) = .empty;
    if (conflict.title) |*fc| try fields.append(aa, try field(c, kind, data, "Title", "title", fc, false));
    if (conflict.labels) |*fc| try fields.append(aa, try field(c, kind, data, "Labels", "labels", fc, false));
    if (comptime @hasField(@TypeOf(conflict), "status")) if (conflict.status) |*fc| try fields.append(aa, try field(c, kind, data, "Status", "status", fc, true));
    if (comptime @hasField(@TypeOf(conflict), "revision")) {
        if (conflict.revision) |*fc| try fields.append(aa, try field(c, kind, data, "Revision", "revision", fc, true));
        if (conflict.target_branch) |*fc| try fields.append(aa, try field(c, kind, data, "Target branch", "target_branch", fc, true));
    }

    var chunks: std.ArrayList(Chunk) = .empty;
    if (conflict.description) |*desc| {
        var hunk_index: usize = 0;
        for (desc.chunks) |chunk| switch (chunk) {
            .same => |text| try chunks.append(aa, .{ .kind = "same", .text = text }),
            .auto => |auto| {
                const author = if (auto.theirs) desc.theirs_author else desc.ours_author;
                const verb: []const u8 = if (auto.text == null) "removed" else "edited";
                try chunks.append(aa, .{ .kind = "auto", .text = auto.text orelse "", .label = switch (author) {
                    .user_name, .email => |name| try c.print("{s} by {s}", .{ verb, name }),
                    .unknown => try c.print("{s} by {s}", .{ verb, if (auto.theirs) @as([]const u8, "them") else "us" }),
                } });
            },
            .conflict => |hunk| {
                const name = try c.print("d{d}", .{hunk_index});
                hunk_index += 1;
                const picked_theirs = data.theirsPicked(name);
                try chunks.append(aa, .{
                    .kind = "conflict",
                    .name = name,
                    .ours = .{ .label = try sideLabel(c, desc.ours_author, true), .text = hunk.ours orelse "", .use_href = try useHref(c, kind, data, name, false), .picked = !picked_theirs },
                    .theirs = .{ .label = try sideLabel(c, desc.theirs_author, false), .text = hunk.theirs orelse "", .use_href = try useHref(c, kind, data, name, true), .picked = picked_theirs },
                    .value = (if (picked_theirs) hunk.theirs else hunk.ours) orelse "",
                });
            },
        };
    }

    const resolve_url = try c.routeUrl(threads.Data(kind).resolveRoute(data.identity, data.selected_id, data.theirs_picks));
    const extra = try aa.dupe(theme.Link, &.{ .{ .label = entry.record.event.title, .href = thread_url }, .{ .label = "Resolve" } });
    try fe.emit(c, w, try repo_views.chrome(c, repo, "Resolve conflicts", extra), "resolve.html", .{
        .noun = n.noun,
        .title = entry.record.event.title,
        .back = thread_url,
        .action = try c.print("{s}/resolve", .{resolve_url}),
        .fields = fields.items,
        .chunks = chunks.items,
        .can_submit = entry.can_modify,
    });
}

fn field(c: Ctx, comptime kind: evt.EventKind, data: *const threads.Data(kind), title: []const u8, comptime name: []const u8, fc: anytype, atomic: bool) !Field {
    const picked_theirs = data.theirsPicked(name);
    return .{
        .title = title,
        .name = name,
        .ours = .{ .label = try sideLabel(c, fc.ours.author, true), .text = fc.ours.text, .use_href = try useHref(c, kind, data, name, false), .picked = !picked_theirs },
        .theirs = .{ .label = try sideLabel(c, fc.theirs.author, false), .text = fc.theirs.text, .use_href = try useHref(c, kind, data, name, true), .picked = picked_theirs },
        .value = if (picked_theirs) fc.theirs.text else fc.ours.text,
        .atomic = atomic,
    };
}

// the label of one side's version, naming its author
fn sideLabel(c: Ctx, author: ui.Author, ours: bool) ![]const u8 {
    return switch (author) {
        .user_name, .email => |name| try c.print("Edited by {s}", .{name}),
        .unknown => if (ours) "Current version" else "Their version",
    };
}

// the resolve page with `name` picked from ours or theirs
fn useHref(c: Ctx, comptime kind: evt.EventKind, data: *const threads.Data(kind), name: []const u8, theirs: bool) ![]const u8 {
    const aa = c.aa();
    var picks: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, data.theirs_picks, ',');
    while (it.next()) |pick| {
        if (pick.len == 0 or std.mem.eql(u8, pick, name)) continue;
        if (picks.items.len > 0) try picks.append(aa, ',');
        try picks.appendSlice(aa, pick);
    }
    if (theirs) {
        if (picks.items.len > 0) try picks.append(aa, ',');
        try picks.appendSlice(aa, name);
    }
    return c.routeUrl(threads.Data(kind).resolveRoute(data.identity, data.selected_id, picks.items));
}
