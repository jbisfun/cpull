// a repo's thread tabs (issues, patches, discussions): the status lists, the
// labels, one thread with its conversation, and the forms that post to cpull's
// thread routes (new, edit, comment, reply, remove, close/reopen).
const std = @import("std");
const ui = @import("../../../ui.zig");
const evt = @import("../../../event.zig");
const theme = @import("../../theme/theme.zig");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const markdown = @import("../markdown.zig");
const repo_views = @import("repo.zig");
const report_views = @import("report.zig");
const Ctx = ctx.Ctx;
const Repo = ui.Repo;
const RoutablePage = ui.RoutablePage;
const Comment = Repo.Comment;

pub fn Data(comptime kind: evt.EventKind) type {
    return switch (kind) {
        .issue => Repo.Issues,
        .discuss => Repo.Discussions,
        .patch => Repo.Patches,
        else => @compileError("not a thread kind: " ++ @tagName(kind)),
    };
}

const Names = struct { noun: []const u8, plural: []const u8, title: []const u8, placeholder: []const u8 };

fn names(comptime kind: evt.EventKind) Names {
    return switch (kind) {
        .issue => .{ .noun = "issue", .plural = "issues", .title = "Issues", .placeholder = "Words, label:name, assignee:name" },
        .discuss => .{ .noun = "discussion", .plural = "discussions", .title = "Discussions", .placeholder = "Words, label:name" },
        .patch => .{ .noun = "patch", .plural = "patches", .title = "Patches", .placeholder = "Words, label:name" },
        else => unreachable,
    };
}

const FormView = enum { new, edit, new_comment, edit_comment, remove };

pub fn panel(c: Ctx, w: *std.Io.Writer, repo: *const Repo, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const view = @tagName(data.view);
    if (std.meta.stringToEnum(FormView, view)) |form| return formPage(c, w, repo, kind, data, form);
    if (std.mem.eql(u8, view, "labels")) return listPage(c, w, repo, kind, data, null, true);
    // conflicts, resolve, publish and merge stay in cpull's terminal UI
    if (std.mem.eql(u8, view, "conflicts") or std.mem.eql(u8, view, "resolve") or std.mem.eql(u8, view, "publish") or std.mem.eql(u8, view, "merge")) {
        return fe.emit(c, w, try repo_views.chrome(c, repo, names(kind).title, &.{}), "message.html", .{
            .title = "Not in the web UI",
            .text = "Resolving conflicts and publishing or merging patches aren't part of the themed web UI yet. Use cpull's terminal UI, or build cpull with -Dfrontend=classic.",
            .links = &[_]theme.Link{.{ .label = "All " ++ comptime names(kind).plural, .href = try firstListUrl(c, kind, data) }},
        });
    }
    const status = std.meta.stringToEnum(Data(kind).Status, view);
    if (data.selected_id.len == 0 or listWindow(c, kind)) return listPage(c, w, repo, kind, data, status, false);
    const entry = data.selectedThread() orelse return notFound(c, w, repo, kind, data);
    try detail(c, w, repo, kind, data, entry);
}

fn listWindow(c: Ctx, comptime kind: evt.EventKind) bool {
    return switch (c.session.current_page) {
        .repo_issues => |*r| kind == .issue and r.start,
        .repo_patches => |*r| kind == .patch and r.start,
        .repo_discussions => |*r| kind == .discuss and r.start,
        else => false,
    };
}

fn statusOf(comptime kind: evt.EventKind, entry: *const Data(kind).Entry) Data(kind).Status {
    return switch (kind) {
        .discuss => .recent,
        else => Data(kind).statusKind(entry.record.event),
    };
}

fn isDraft(comptime kind: evt.EventKind, entry: *const Data(kind).Entry) bool {
    return if (kind == .patch) entry.draft else false;
}

fn isConflicted(comptime kind: evt.EventKind, entry: *const Data(kind).Entry) bool {
    return if (@hasField(Data(kind).Entry, "conflicted")) entry.conflicted else false;
}

fn threadUrl(c: Ctx, comptime kind: evt.EventKind, identity: []const u8, id: []const u8) ![]const u8 {
    return c.routeUrl(RoutablePage.repoThreadCommentsRoute(kind, identity, id, 0));
}

fn listUrl(c: Ctx, comptime kind: evt.EventKind, identity: []const u8, status: Data(kind).Status, search: []const u8) ![]const u8 {
    return c.url(try ui.widget.thread.searchRoute(Data(kind).listRoute(identity, status, ""), if (search.len == 0) null else search));
}

fn firstListUrl(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind)) ![]const u8 {
    return listUrl(c, kind, data.identity, std.enums.values(Data(kind).Status)[0], "");
}

// `search` with its `prefix` terms replaced by one for `value`, put first
fn withFilter(c: Ctx, search: []const u8, prefix: []const u8, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.aa());
    try out.writer.print("{s}{s}", .{ prefix, value });
    var terms = std.mem.tokenizeAny(u8, search, &std.ascii.whitespace);
    while (terms.next()) |term| {
        if (!std.mem.startsWith(u8, term, prefix)) try out.writer.print(" {s}", .{term});
    }
    return out.written();
}

fn capitalized(comptime word: []const u8) []const u8 {
    comptime {
        var buf: [word.len]u8 = word[0..word.len].*;
        buf[0] = std.ascii.toUpper(buf[0]);
        const result = buf;
        return &result;
    }
}

fn statusLabel(status: anytype) []const u8 {
    return switch (status) {
        inline else => |value| comptime capitalized(@tagName(value)),
    };
}

const Chip = struct { label: []const u8, href: []const u8 };

fn labelChips(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), status: Data(kind).Status, labels: []const u8) ![]const Chip {
    var list: std.ArrayList(Chip) = .empty;
    var it = std.mem.tokenizeScalar(u8, labels, ' ');
    while (it.next()) |label| try list.append(c.aa(), .{
        .label = label,
        .href = try listUrl(c, kind, data.identity, status, try withFilter(c, data.search orelse "", "label:", label)),
    });
    return list.items;
}

const Row = struct {
    title: []const u8,
    href: []const u8,
    status: []const u8,
    ball: []const u8,
    author: ctx.Person,
    opened: theme.Time,
    comments: usize,
    labels: []const Chip,
    assignees: []const []const u8,
    draft: bool,
    conflict: bool,
};

fn listPage(c: Ctx, w: *std.Io.Writer, repo: *const Repo, comptime kind: evt.EventKind, data: *const Data(kind), status: ?Data(kind).Status, labels_view: bool) !void {
    const n = comptime names(kind);
    const aa = c.aa();
    const view = @tagName(data.view);
    const search = data.search orelse "";

    var tabs: std.ArrayList(theme.Link) = .empty;
    for (std.enums.values(Data(kind).Status)) |s| {
        const win = data.window(s);
        try tabs.append(aa, .{ .label = statusLabel(s), .href = try listUrl(c, kind, data.identity, s, search), .active = std.mem.eql(u8, view, @tagName(s)), .count = win.count });
    }
    try tabs.append(aa, .{ .label = "Labels", .href = try c.url(try ui.widget.thread.searchRoute(RoutablePage.repoThreadLabelsRoute(kind, data.identity), data.search)), .active = labels_view });
    if (kind == .patch) if (c.server() and (data.drafts.count > 0 or data.view == .drafts)) {
        try tabs.append(aa, .{ .label = "Drafts", .href = try c.routeUrl(Data(kind).draftsRoute(data.identity)), .active = data.view == .drafts, .count = data.drafts.count });
    };
    if (comptime @hasField(Data(kind), "conflicts")) if (data.conflicts.count > 0) {
        try tabs.append(aa, .{ .label = "Conflicts", .href = try c.routeUrl(Data(kind).conflictsRoute(data.identity, "")), .count = data.conflicts.count });
    };

    var rows: std.ArrayList(Row) = .empty;
    var label_chips: []const Chip = &.{};
    var prev: []const u8 = "";
    var next: []const u8 = "";
    var empty: []const u8 = "";
    if (labels_view) {
        var list: std.ArrayList(Chip) = .empty;
        const first = std.enums.values(Data(kind).Status)[0];
        for (data.labels) |label| try list.append(aa, .{ .label = label, .href = try listUrl(c, kind, data.identity, first, try withFilter(c, search, "label:", label)) });
        label_chips = list.items;
        if (list.items.len == 0) empty = "No " ++ n.noun ++ " has a label yet.";
    } else {
        const win = if (status) |value| data.window(value) else switch (kind) {
            .patch => &data.drafts,
            else => data.window(std.enums.values(Data(kind).Status)[0]),
        };
        for (win.items) |*entry| {
            const s = statusOf(kind, entry);
            var assignees: std.ArrayList([]const u8) = .empty;
            for (entry.assignees) |assignee| try assignees.append(aa, assignee.display());
            try rows.append(aa, .{
                .title = entry.record.event.title,
                .href = try threadUrl(c, kind, data.identity, entry.id),
                .status = statusLabel(s),
                .ball = if (isConflicted(kind, entry)) "conflict" else @tagName(s),
                .author = try c.author(entry.author),
                .opened = try c.time(ctx.seconds(entry.record.created_timestamp)),
                .comments = entry.comments.count,
                .labels = try labelChips(c, kind, data, s, entry.record.event.labels),
                .assignees = assignees.items,
                .draft = isDraft(kind, entry),
                .conflict = isConflicted(kind, entry),
            });
        }
        const list_name = if (status) |value| try c.print("{s} {s}", .{ @tagName(value), n.plural }) else "drafts";
        if (win.items.len == 0) empty = if (win.prev_id != null) try c.print("No more {s}.", .{list_name}) else if (data.search != null) try c.print("No {s} match this search.", .{list_name}) else try c.print("No {s}.", .{list_name});
        for ([_]?[]const u8{ win.prev_id, win.next_id }, 0..) |id_maybe, i| {
            const id = id_maybe orelse continue;
            const list_route = (if (status) |value| Data(kind).listRoute(data.identity, value, "") else if (kind == .patch) Data(kind).draftsRoute(data.identity) else null) orelse return error.RouteTooLong;
            var route = list_route.startingAt(id) orelse return error.RouteTooLong;
            if (status != null) if (data.search) |query| {
                route = route.withSearch(query) orelse return error.RouteTooLong;
            };
            if (i == 0) prev = try c.url(route) else next = try c.url(route);
        }
    }

    const View = Data(kind).View;
    const search_action = try c.routeUrl(View.searchListRoute(data.identity, View.viewIndex(data.view)));
    try fe.emit(c, w, try repo_views.chrome(c, repo, n.title, &.{}), "threads.html", .{
        .noun = n.noun,
        .plural = n.plural,
        .title = n.title,
        .kind = @tagName(kind),
        .tabs = tabs.items,
        .labels_view = labels_view,
        .label_chips = label_chips,
        .search_action = search_action,
        .search = search,
        .placeholder = n.placeholder,
        .clear_href = if (data.search != null) (if (status) |value| try listUrl(c, kind, data.identity, value, "") else try firstListUrl(c, kind, data)) else "",
        .new_href = if (data.viewer != null) try c.routeUrl(RoutablePage.repoThreadNewRoute(kind, data.identity)) else "",
        .rows = rows.items,
        .empty = empty,
        .prev = prev,
        .next = next,
    });
}

fn notFound(c: Ctx, w: *std.Io.Writer, repo: *const Repo, comptime kind: evt.EventKind, data: *const Data(kind)) !void {
    const n = comptime names(kind);
    try fe.emit(c, w, try repo_views.chrome(c, repo, n.title, &.{}), "message.html", .{
        .title = comptime capitalized(n.noun) ++ " not found",
        .text = "There is no " ++ n.noun ++ " with this id in this repository. It may have been removed.",
        .links = &[_]theme.Link{.{ .label = "All " ++ n.plural, .href = try firstListUrl(c, kind, data) }},
    });
}

const CommentView = struct {
    id: []const u8,
    author: ctx.Person,
    time: theme.Time,
    permalink: []const u8,
    body: theme.vin.Str,
    removed: bool,
    reply_to: []const u8,
    reply_to_href: []const u8,
    reply_href: []const u8,
    edit_href: []const u8,
    remove_href: []const u8,
    focused: bool,
};

fn commentView(c: Ctx, comptime kind: evt.EventKind, data: *const Data(kind), comment: *const Comment.CommentWithId, focused: bool) !CommentView {
    const thread_id: []const u8 = &comment.comment.event.thread_id;
    const parent_id: []const u8 = &comment.comment.event.parent_id;
    const modifiable = comment.can_modify and !comment.comment.removed;
    const is_reply = !std.mem.eql(u8, parent_id, thread_id);
    return .{
        .id = try c.aa().dupe(u8, &comment.id),
        .author = try c.author(comment.author),
        .time = try c.time(ctx.seconds(comment.comment.created_timestamp)),
        .permalink = try c.routeUrl(RoutablePage.repoThreadCommentRoute(kind, data.identity, thread_id, &comment.id, 0)),
        .body = if (comment.comment.removed) theme.markup("") else try markdown.render(c.aa(), comment.comment.event.body),
        .removed = comment.comment.removed,
        .reply_to = if (is_reply) (if (comment.parent_author) |p| (try c.author(p)).name else "a comment") else "",
        .reply_to_href = if (is_reply) try c.routeUrl(RoutablePage.repoThreadCommentRoute(kind, data.identity, thread_id, parent_id, 0)) else "",
        .reply_href = if (data.viewer != null) try c.routeUrl(RoutablePage.repoThreadCommentNewRoute(kind, data.identity, thread_id, &comment.id)) else "",
        .edit_href = if (modifiable) try c.routeUrl(RoutablePage.repoThreadCommentEditRoute(kind, data.identity, thread_id, &comment.id)) else "",
        .remove_href = if (modifiable) try c.routeUrl(RoutablePage.repoThreadRemoveRoute(kind, data.identity, thread_id, &comment.id, "")) else "",
        .focused = focused,
    };
}

fn windowUrl(c: Ctx, comptime kind: evt.EventKind, identity: []const u8, thread_id: []const u8, selected: ?[]const u8, start: usize) ![]const u8 {
    const route = if (selected) |id| RoutablePage.repoThreadCommentRoute(kind, identity, thread_id, id, start) else RoutablePage.repoThreadCommentsRoute(kind, identity, thread_id, start);
    return c.routeUrl(route);
}

const Attachment = struct { name: []const u8, href: []const u8, remove_href: []const u8 };
const Assignee = struct { name: []const u8, href: []const u8, unassign_action: []const u8 };
const Fact = struct { term: []const u8, value: []const u8, href: []const u8 = "", mono: bool = false };

fn detail(c: Ctx, w: *std.Io.Writer, repo: *const Repo, comptime kind: evt.EventKind, data: *const Data(kind), entry: *const Data(kind).Entry) !void {
    const n = comptime names(kind);
    const aa = c.aa();
    const status = statusOf(kind, entry);
    const draft = isDraft(kind, entry);
    const thread_url = try threadUrl(c, kind, data.identity, entry.id);
    const event = &entry.record.event;

    // the conversation, or a comment's own page with its replies
    var comments: std.ArrayList(CommentView) = .empty;
    var focused: ?CommentView = null;
    var count: usize = entry.comments.count;
    var prev: []const u8 = "";
    var next: []const u8 = "";
    var compose_action = try c.routeUrl(RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, ""));
    var compose_label: []const u8 = "Add a comment";
    {
        const win: *const Comment.Window, const selected: ?[]const u8 = if (data.comment_page) |*p| .{ &p.replies, &p.selected.id } else .{ &entry.comments, null };
        if (data.comment_page) |*p| {
            focused = try commentView(c, kind, data, &p.selected, true);
            count = p.replies.count;
            compose_action = try c.routeUrl(RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, &p.selected.id));
            compose_label = try c.print("Reply to {s}", .{(try c.author(p.selected.author)).name});
        }
        for (win.comments) |*comment| try comments.append(aa, try commentView(c, kind, data, comment, false));
        const has_more = win.start < win.count and win.count - win.start > Comment.page_size;
        if (win.start > 0) prev = try windowUrl(c, kind, data.identity, entry.id, selected, win.start -| Comment.page_size);
        if (has_more) next = try windowUrl(c, kind, data.identity, entry.id, selected, win.start + Comment.page_size);
    }

    const description = event.description;
    const preview_end = if (data.description_page) null else ui.detailPreviewEnd(description);
    const shown_description = if (preview_end) |end| std.mem.trimEnd(u8, description[0..end], " \t\r\n") else description;

    var assignees: std.ArrayList(Assignee) = .empty;
    if (kind == .issue) for (entry.assignees) |assignee| {
        const name = assignee.display();
        try assignees.append(aa, .{
            .name = name,
            .href = try listUrl(c, kind, data.identity, status, try withFilter(c, data.search orelse "", "assignee:", name)),
            .unassign_action = if (entry.can_modify) try c.print("{s}/assignee:{s}/unassign", .{ thread_url, try ui.urlEncodeRef(aa, assignee.email) }) else "",
        });
    };
    var attachments: std.ArrayList(Attachment) = .empty;
    for (entry.attachments) |*attachment| try attachments.append(aa, .{
        .name = attachment.name,
        .href = if (data.identity.len == 0) try c.print("/attachment:{s}", .{&attachment.id}) else try c.print("/{s}/attachment:{s}", .{ data.identity, &attachment.id }),
        .remove_href = if (entry.can_modify) try c.routeUrl(RoutablePage.repoThreadRemoveRoute(kind, data.identity, entry.id, "", &attachment.id)) else "",
    });

    // a patch's proposal
    var facts: std.ArrayList(Fact) = .empty;
    if (kind == .patch) {
        if (event.source_branch) |branch| {
            try facts.append(aa, .{ .term = "Source", .value = branch, .href = try c.routeUrl(RoutablePage.repoFilesRoute(data.identity, .branch, try ui.urlEncodeRef(aa, branch), "", 0)), .mono = true });
        } else try facts.append(aa, .{ .term = "Source", .value = if (entry.fork_exists) entry.fork_identity else "a removed fork" });
        try facts.append(aa, .{ .term = "Target", .value = event.target_branch, .href = try c.routeUrl(RoutablePage.repoFilesRoute(data.identity, .branch, try ui.urlEncodeRef(aa, event.target_branch), "", 0)), .mono = true });
        if (event.revision) |*revision| {
            const rev: []const u8 = &revision.id;
            try facts.append(aa, .{ .term = "Revision", .value = ctx.short(rev), .href = try c.routeUrl(RoutablePage.repoPatchRevDiffRoute(data.identity, rev, 0, "")), .mono = true });
        }
    }

    const open = std.mem.eql(u8, @tagName(status), "open");
    const closed = std.mem.eql(u8, @tagName(status), "closed");
    const can_act = entry.can_modify and !isConflicted(kind, entry);
    const anchor: ?report_views.AnchorView = if (kind == .issue) try report_views.anchorView(c, data.identity, event.anchor, data.excerpt) else null;
    const extra = try aa.dupe(theme.Link, &.{.{ .label = event.title }});
    try fe.emit(c, w, try repo_views.chrome(c, repo, event.title, extra), "thread.html", .{
        .noun = n.noun,
        .kind = @tagName(kind),
        .title = event.title,
        .status = if (kind == .discuss) "" else if (draft) "Draft" else statusLabel(status),
        .ball = if (isConflicted(kind, entry)) "conflict" else @tagName(status),
        .author = try c.author(entry.author),
        .opened = try c.time(ctx.seconds(entry.record.created_timestamp)),
        .back_href = try listUrl(c, kind, data.identity, status, data.search orelse ""),
        .back_label = try c.print("{s} {s}", .{ statusLabel(status), n.plural }),
        .thread_href = thread_url,
        .description = try markdown.render(aa, shown_description),
        .has_description = description.len > 0,
        .more_href = if (preview_end != null) try c.routeUrl(RoutablePage.repoThreadDescriptionRoute(kind, data.identity, entry.id)) else "",
        .labels = try labelChips(c, kind, data, status, event.labels),
        .assignees = assignees.items,
        .assign_action = if (kind == .issue and entry.can_modify) try c.print("{s}/assign", .{thread_url}) else "",
        .assign_placeholder = if (c.server()) "Username or email" else "Email",
        .attachments = attachments.items,
        .facts = facts.items,
        .anchor = anchor,
        .conflict = isConflicted(kind, entry),
        .focused = focused,
        .comments = comments.items,
        .comment_count = count,
        .show_conversation = !draft,
        .prev = prev,
        .next = next,
        .compose_action = if (data.viewer != null and !draft) compose_action else "",
        .compose_label = compose_label,
        .close_action = if (can_act and kind != .discuss and !draft and open) try c.print("{s}/close", .{thread_url}) else "",
        .open_action = if (can_act and kind != .discuss and !draft and closed) try c.print("{s}/open", .{thread_url}) else "",
        .edit_href = if (can_act) try c.routeUrl(RoutablePage.repoThreadEditRoute(kind, data.identity, entry.id)) else "",
        .remove_href = if (entry.can_modify) try c.routeUrl(RoutablePage.repoThreadRemoveRoute(kind, data.identity, entry.id, "", "")) else "",
    });
}

// --- forms ---------------------------------------------------------------

const Field = struct {
    label: []const u8,
    name: []const u8,
    value: []const u8,
    hint: []const u8 = "",
    textarea: bool = false,
    mono: bool = false,
    invalid: bool = false,
    rows: usize = 12,
};

const PatchFailure = ui.Session.FormFeedback.PatchFailure;

fn feedbackTag(comptime kind: evt.EventKind) std.meta.Tag(ui.Session.FormFeedback) {
    return switch (kind) {
        .issue => .issue,
        .discuss => .discussion,
        .patch => .patch,
        else => unreachable,
    };
}

fn savedFailure(c: Ctx, comptime kind: evt.EventKind) ?PatchFailure {
    const saved = c.feedback(comptime feedbackTag(kind)) orelse return null;
    return std.meta.stringToEnum(PatchFailure, @tagName(saved.failure));
}

fn failureText(failure: PatchFailure) []const u8 {
    return switch (failure) {
        .required_title => "Enter a title.",
        .invalid_target_branch => "There is no branch by that name to target.",
        .invalid_source_branch => "There is no source branch by that name.",
        .same_branch => "The source and target branches are the same.",
        .unrelated_branches => "The source and target branches share no history.",
    };
}

const Fields = struct {
    title: []const u8 = "",
    labels: []const u8 = "",
    description: []const u8 = "",
    target_branch: []const u8 = "",
    source_branch: []const u8 = "",
};

fn savedFields(c: Ctx, comptime kind: evt.EventKind) ?Fields {
    const saved = c.feedback(comptime feedbackTag(kind)) orelse return null;
    const fields = saved.fields orelse return null;
    var result: Fields = .{ .title = fields.title, .labels = fields.labels, .description = fields.description };
    if (kind == .patch) {
        result.target_branch = fields.target_branch;
        result.source_branch = fields.source_branch;
    }
    return result;
}

fn threadFields(c: Ctx, comptime kind: evt.EventKind, fields: Fields, failure: ?PatchFailure, source: bool) ![]const Field {
    var list: std.ArrayList(Field) = .empty;
    const aa = c.aa();
    try list.append(aa, .{ .label = "Title", .name = "title", .value = fields.title, .invalid = failure == .required_title });
    try list.append(aa, .{ .label = "Labels", .name = "labels", .value = fields.labels, .hint = "Separate labels with spaces." });
    try list.append(aa, .{ .label = "Description", .name = "description", .value = fields.description, .textarea = true, .hint = "Markdown." });
    if (kind == .patch) {
        const branches_failed = failure == .invalid_source_branch or failure == .same_branch or failure == .unrelated_branches;
        if (source) try list.append(aa, .{ .label = "Source branch", .name = "source_branch", .value = fields.source_branch, .mono = true, .invalid = branches_failed, .hint = "The branch whose commits the patch proposes; pushes to it update the patch." });
        try list.append(aa, .{ .label = "Target branch", .name = "target_branch", .value = fields.target_branch, .mono = true, .invalid = failure == .invalid_target_branch or (!source and branches_failed), .hint = "The branch the patch would be merged into." });
    }
    return list.items;
}

fn formPage(c: Ctx, w: *std.Io.Writer, repo: *const Repo, comptime kind: evt.EventKind, data: *const Data(kind), form: FormView) !void {
    const n = comptime names(kind);
    const aa = c.aa();
    if (c.server() and data.viewer == null) {
        return fe.emit(c, w, try repo_views.chrome(c, repo, n.title, &.{}), "message.html", .{
            .title = "You can't write here",
            .text = "Your role in this repository doesn't let you write in its " ++ n.plural ++ ".",
            .links = &[_]theme.Link{.{ .label = "All " ++ n.plural, .href = try firstListUrl(c, kind, data) }},
        });
    }
    const failure = savedFailure(c, kind);
    var heading: []const u8 = "";
    var subtitle: []const u8 = "";
    var action: []const u8 = "";
    var back: []const u8 = "";
    var submit: []const u8 = "";
    var fields: []const Field = &.{};
    var confirm: []const u8 = "";
    var quoted: ?CommentView = null;
    var crumb: []const u8 = "";
    switch (form) {
        .new => {
            heading = "New " ++ n.noun;
            crumb = heading;
            if (kind == .patch) subtitle = "Propose a branch of this repository; pushes to it update the patch.";
            action = try c.routeUrl(RoutablePage.repoThreadNewRoute(kind, data.identity));
            back = try firstListUrl(c, kind, data);
            submit = "Create " ++ n.noun;
            var values = savedFields(c, kind) orelse Fields{};
            if (kind == .patch and savedFields(c, kind) == null) values.target_branch = data.default_target_branch;
            fields = try threadFields(c, kind, values, failure, true);
        },
        .edit => {
            const entry = data.selectedThread() orelse return notFound(c, w, repo, kind, data);
            const event = &entry.record.event;
            heading = "Edit " ++ n.noun;
            crumb = "Edit";
            subtitle = event.title;
            action = try c.routeUrl(RoutablePage.repoThreadEditRoute(kind, data.identity, entry.id));
            back = try threadUrl(c, kind, data.identity, entry.id);
            submit = "Save changes";
            fields = try threadFields(c, kind, savedFields(c, kind) orelse .{
                .title = event.title,
                .labels = event.labels,
                .description = event.description,
                .target_branch = if (kind == .patch) event.target_branch else "",
            }, failure, false);
        },
        .new_comment, .edit_comment => {
            const entry = data.selectedThread() orelse return notFound(c, w, repo, kind, data);
            const editing = form == .edit_comment;
            const thread_url = try threadUrl(c, kind, data.identity, entry.id);
            var body: []const u8 = "";
            if (data.comment_page) |*p| {
                const selected = &p.selected;
                back = try c.routeUrl(RoutablePage.repoThreadCommentRoute(kind, data.identity, entry.id, &selected.id, 0));
                if (editing) {
                    heading = "Edit comment";
                    subtitle = try c.print("On {s}", .{entry.record.event.title});
                    body = selected.comment.event.body;
                    action = try c.routeUrl(RoutablePage.repoThreadCommentEditRoute(kind, data.identity, entry.id, &selected.id));
                } else {
                    heading = try c.print("Reply to {s}", .{(try c.author(selected.author)).name});
                    quoted = try commentView(c, kind, data, selected, false);
                    action = try c.routeUrl(RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, &selected.id));
                }
            } else {
                heading = try c.print("Comment on {s}", .{entry.record.event.title});
                back = thread_url;
                action = try c.routeUrl(RoutablePage.repoThreadCommentNewRoute(kind, data.identity, entry.id, ""));
            }
            crumb = if (editing) "Edit comment" else "Comment";
            submit = if (editing) "Save comment" else if (data.comment_page != null) "Reply" else "Comment";
            fields = try aa.dupe(Field, &.{.{ .label = "Comment", .name = "body", .value = body, .textarea = true, .rows = 8, .hint = "Markdown." }});
        },
        .remove => {
            const entry = data.selectedThread() orelse return notFound(c, w, repo, kind, data);
            const attachment_id = c.session.current_page.threadAttachment();
            const thread_url = try threadUrl(c, kind, data.identity, entry.id);
            subtitle = entry.record.event.title;
            if (attachment_id.len != 0) {
                const name = for (entry.attachments) |*attachment| {
                    if (std.mem.eql(u8, &attachment.id, attachment_id)) break attachment.name;
                } else return notFound(c, w, repo, kind, data);
                heading = "Remove attachment";
                confirm = try c.print("Remove {s} from this {s}? It is removed for everyone.", .{ name, n.noun });
                back = thread_url;
            } else if (data.comment_id.len != 0) {
                heading = "Remove comment";
                confirm = "Remove this comment? It shows as removed for everyone; its replies stay.";
                back = try c.routeUrl(RoutablePage.repoThreadCommentRoute(kind, data.identity, entry.id, data.comment_id, 0));
            } else {
                heading = "Remove " ++ n.noun;
                confirm = "Remove this " ++ n.noun ++ "? It is removed for everyone, with its comments.";
                back = thread_url;
            }
            crumb = heading;
            submit = heading;
            action = try c.routeUrl(RoutablePage.repoThreadRemoveRoute(kind, data.identity, entry.id, data.comment_id, attachment_id));
        },
    }
    try fe.emit(c, w, try repo_views.chrome(c, repo, heading, try aa.dupe(theme.Link, &.{.{ .label = crumb }})), "thread_form.html", .{
        .heading = heading,
        .subtitle = subtitle,
        .action = action,
        .back = back,
        .submit = submit,
        .fields = fields,
        .confirm = confirm,
        .quoted = quoted,
        .error_text = if (failure) |f| failureText(f) else "",
    });
}
