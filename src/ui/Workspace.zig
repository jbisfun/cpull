// the workspace pages of a pull workspace in local mode: every repo of the
// pullfile, the issues and patches across them, and the stacks (changes that
// span several repos). the data is read on the host (see workspace.zig) and
// travels in the page snapshot; the page itself is markdown, so it renders
// the same in the terminal and on the web, plus a merge form on a stack page.
const std = @import("std");
const ui = @import("../ui.zig");
const md = @import("../markdown.zig");
const Markdown = @import("./Repo/Markdown.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");

pub const RepoRow = struct {
    // the pullfile name, maybe nested ("group/name")
    name: []const u8,
    // "owner:key", the repo page's identity
    identity: []const u8,
    // the group dir of a nested repo
    group: ?[]const u8 = null,
    // the pullfile branch, which patches target
    branch: []const u8,
    cloned: bool = false,
    // the checked-out branch, null when detached
    head_branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    pin: ?[]const u8 = null,
    // the head moved past the pin
    ahead: bool = false,
    open_issues: usize = 0,
    open_patches: usize = 0,
};

pub const IssueRow = struct {
    repo: []const u8,
    identity: []const u8,
    id: []const u8,
    title: []const u8,
    labels: []const u8,
    url: []const u8,
};

pub const PatchRow = struct {
    repo: []const u8,
    identity: []const u8,
    id: []const u8,
    title: []const u8,
    source_branch: []const u8,
    target_branch: []const u8,
    status: []const u8,
    url: []const u8,
};

pub const StackRow = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    members: usize,
    conflicted_fields: []const u8 = "",
    url: []const u8,
};

pub const MemberRow = struct {
    repo: []const u8,
    identity: ?[]const u8 = null,
    patch_id: []const u8,
    title: []const u8 = "",
    source_branch: []const u8 = "",
    target_branch: []const u8 = "",
    // the member patch's status, or "missing" when its repo or patch isn't here
    status: []const u8,
    // what merging it now would do: fast_forward, clean, nothing, conflict,
    // merged, or why it can't (missing, closed, checked_out, out_of_date)
    mergeable: []const u8 = "unknown",
    // the target branch's tip, or after a merge the commit it pinned
    target_oid: ?[]const u8 = null,
    // the pullfile pin, so a merged stack shows whether pull recorded it
    pin: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const StackDetail = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    labels: []const u8,
    status: []const u8,
    author_email: ?[]const u8 = null,
    conflicted_fields: []const u8 = "",
    members: []const MemberRow = &.{},
    // every member can merge now
    mergeable: bool = false,
};

pub const View_ = ui.RoutablePage.WorkspaceView;

// the workspace's name, which every repo identity carries as its owner
name: []const u8,
view: View_ = .home,
// the repo holding the workspace's own issues and stacks, if any
events_identity: ?[]const u8 = null,
repos: []const RepoRow = &.{},
issues: []const IssueRow = &.{},
patches: []const PatchRow = &.{},
stacks: []const StackRow = &.{},
stack: ?StackDetail = null,
// the page as markdown, rendered once on the host
text: []const u8 = "",

const Self = @This();

pub fn stackUrl(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    return arena.print("/home/stacks/{s}", .{id});
}

// the page's markdown. links to repo pages carry their identity, and the
// workspace pages live under /home, so they resolve in workspace mode
pub fn render(arena: std.mem.Allocator, data: Self) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("# {s}\n\n", .{data.name});
    const tabs = [_]struct { View_, []const u8, []const u8 }{
        .{ .home, "repos", "/" },
        .{ .issues, "issues", "/home/issues" },
        .{ .patches, "patches", "/home/patches" },
        .{ .stacks, "stacks", "/home/stacks" },
    };
    for (tabs, 0..) |tab, i| {
        if (i > 0) try w.writeAll(" · ");
        const selected = tab[0] == data.view or (tab[0] == .stacks and data.view == .stack);
        if (selected) try w.print("**{s}**", .{tab[1]}) else try w.print("[{s}]({s})", .{ tab[1], tab[2] });
    }
    try w.writeAll("\n\n");
    switch (data.view) {
        .home => {
            if (data.events_identity) |identity| try w.print("Workspace [issues](/{s}/issues) and [discussions](/{s}/discussions) live in [{s}](/{s}).\n\n", .{ identity, identity, identity, identity });
            var group: ?[]const u8 = null;
            for (data.repos) |repo| {
                if (!optEql(group, repo.group)) {
                    group = repo.group;
                    if (repo.group) |g| try w.print("\n## {s}/\n\n", .{g});
                }
                try w.print("- [{s}](/{s}) ", .{ repo.name, repo.identity });
                if (!repo.cloned) {
                    try w.writeAll("not cloned\n");
                    continue;
                }
                try w.print("`{s}`", .{repo.head_branch orelse "(detached)"});
                if (repo.head_branch == null or !std.mem.eql(u8, repo.head_branch.?, repo.branch)) try w.print(" (pins `{s}`)", .{repo.branch});
                if (repo.head) |head| try w.print(" {s}", .{head[0..@min(8, head.len)]});
                if (repo.ahead) try w.writeAll(", past its pin");
                if (repo.pin == null) try w.writeAll(", unpinned");
                if (repo.open_issues > 0) try w.print(", [{d} open issue{s}](/{s}/issues)", .{ repo.open_issues, plural(repo.open_issues), repo.identity });
                if (repo.open_patches > 0) try w.print(", [{d} open patch{s}](/{s}/patches)", .{ repo.open_patches, if (repo.open_patches == 1) "" else "es", repo.identity });
                try w.writeAll("\n");
            }
        },
        .issues => {
            if (data.issues.len == 0) try w.writeAll("No open issues in any repo.\n");
            var repo: ?[]const u8 = null;
            for (data.issues) |issue| {
                if (repo == null or !std.mem.eql(u8, repo.?, issue.repo)) {
                    repo = issue.repo;
                    try w.print("\n## [{s}](/{s}/issues)\n\n", .{ issue.repo, issue.identity });
                }
                try w.print("- [{s}]({s})", .{ issue.title, issue.url });
                if (issue.labels.len > 0) try w.print(" `{s}`", .{issue.labels});
                try w.writeAll("\n");
            }
        },
        .patches => {
            if (data.patches.len == 0) try w.writeAll("No open patches in any repo.\n");
            var repo: ?[]const u8 = null;
            for (data.patches) |patch| {
                if (repo == null or !std.mem.eql(u8, repo.?, patch.repo)) {
                    repo = patch.repo;
                    try w.print("\n## [{s}](/{s}/patches)\n\n", .{ patch.repo, patch.identity });
                }
                try w.print("- [{s}]({s}) `{s}` → `{s}`\n", .{ patch.title, patch.url, patch.source_branch, patch.target_branch });
            }
        },
        .stacks => {
            if (data.stacks.len == 0) try w.writeAll("No stacks yet. `pull haxy patch` turns work across repos into one.\n");
            for (data.stacks) |stack| {
                try w.print("- [{s}]({s}) {s}, {d} repo{s}", .{ stack.title, stack.url, stack.status, stack.members, plural(stack.members) });
                if (stack.conflicted_fields.len > 0) try w.print(", conflicted: {s}", .{stack.conflicted_fields});
                try w.writeAll("\n");
            }
        },
        .stack => if (data.stack) |stack| {
            try w.print("## {s}\n\n", .{stack.title});
            try w.print("{s}", .{stack.status});
            if (stack.labels.len > 0) try w.print(" `{s}`", .{stack.labels});
            if (stack.author_email) |email| try w.print(", by {s}", .{email});
            try w.writeAll("\n\n");
            if (stack.conflicted_fields.len > 0) try w.print("Conflicted after a sync: {s}. Any edit settles it.\n\n", .{stack.conflicted_fields});
            if (stack.description.len > 0) try w.print("{s}\n\n", .{stack.description});
            try w.writeAll("| repo | patch | branches | status | merge |\n|---|---|---|---|---|\n");
            for (stack.members) |member| {
                if (member.url) |url| try w.print("| {s} | [{s}]({s}) ", .{ member.repo, if (member.title.len > 0) member.title else member.patch_id[0..8], url }) else try w.print("| {s} | {s} ", .{ member.repo, member.patch_id[0..8] });
                try w.print("| `{s}` → `{s}` | {s} | {s}", .{ member.source_branch, member.target_branch, member.status, member.mergeable });
                if (member.target_oid) |oid| {
                    try w.print(" {s}", .{oid[0..@min(8, oid.len)]});
                    if (member.pin) |pin| {
                        if (!std.mem.eql(u8, pin, oid)) try w.print(" (pinned {s})", .{pin[0..@min(8, pin.len)]});
                    }
                }
                try w.writeAll(" |\n");
            }
            if (std.mem.eql(u8, stack.status, "open")) {
                try w.writeAll(if (stack.mergeable) "\nEvery member merges cleanly. Merging moves each target branch, marks the patches merged, and pins the new commits with pull.\n" else "\nNot every member can merge yet.\n");
            }
        } else try w.writeAll("No such stack.\n"),
    }
    return out.written();
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u8, x, y) else false;
    return b == null;
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    session: *ui.Session,
    // the merge button of an open, mergeable stack
    button_id: ?usize = null,
    stack_id: ?[]const u8 = null,

    const frame_index = 0;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);

        {
            const doc = try md.parseText(session.page_arena.allocator(), data.text);
            var scroll = blk: {
                var markdown = try Markdown.View.init(allocator, session, doc, null, "", null);
                errdefer markdown.deinit(allocator);
                break :blk try wgt.Scroll(ui.Widget).init(allocator, .{ .markdown = markdown }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            };
            errdefer scroll.deinit(allocator);
            var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border = .single, .round_corners = true, .direction = .vert });
            errdefer frame.deinit(allocator);
            frame.getFocus().child_id = scroll.getFocus().id;
            try frame.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null, .flex = .grow });
            try box.children.put(allocator, frame.getFocus().id, .{ .widget = .{ .box = frame }, .rect = null, .min_size = null, .flex = .grow });
        }

        var button_id: ?usize = null;
        var stack_id: ?[]const u8 = null;
        if (data.stack) |stack| if (data.view == .stack and stack.mergeable and std.mem.eql(u8, stack.status, "open")) {
            var row = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer row.deinit(allocator);
            row.getFocus().kind = .{ .custom = try session.page_arena.allocator().print("form:{s}/merge", .{try stackUrl(session.page_arena.allocator(), stack.id)}) };
            var button = try ui.widget.SubmitButton.initLabeled(allocator, "merge stack");
            errdefer button.deinit(allocator);
            button_id = button.box.children.keys()[1];
            row.getFocus().child_id = button.getFocus().id;
            try row.children.put(allocator, button.getFocus().id, .{ .widget = .{ .submit_button = button }, .rect = null, .min_size = null });
            try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = null });
            stack_id = stack.id;
        };

        box.getFocus().child_id = box.children.keys()[frame_index];
        return .{ .box = box, .session = session, .button_id = button_id, .stack_id = stack_id };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const focused = if (root_focus.grandchild_id) |id| self.markdownView().owns(id) else false;
        self.frameBox().options.border = if (focused) .double else .single;
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        if (!self.session.is_terminal) return;
        const on_button = if (self.button_id) |id| root_focus.grandchild_id == id or self.box.getFocus().child_id != self.box.children.keys()[frame_index] else false;
        if (self.button_id) |id| switch (key) {
            .enter => if (on_button) return self.requestMerge(),
            .mouse => |mouse| if (inp.leftClickOn(root_focus, id, mouse)) return self.requestMerge(),
            .arrow_down => if (!on_button and atBottom(self.contentScroll())) {
                root_focus.setFocus(id);
                return;
            },
            .arrow_up => if (on_button) {
                root_focus.setFocus(self.box.children.keys()[frame_index]);
                return;
            },
            else => {},
        };
        if (on_button) return;
        try self.markdownView().input(allocator, key, root_focus);
        const sc = self.contentScroll();
        switch (key) {
            .arrow_up => sc.y -= 1,
            .arrow_down => sc.y += 1,
            .page_up => sc.y -= 10,
            .page_down => sc.y += 10,
            .home => sc.y = 0,
            .end => sc.y = std.math.maxInt(isize),
            .scroll_up => sc.y -= 5,
            .scroll_down => sc.y += 5,
            .tab, .back_tab => try self.markdownView().stepLink(allocator, root_focus, sc, 0, 0, key == .tab),
            else => {},
        }
        sc.clampToContent();
    }

    fn atBottom(sc: *const wgt.Scroll(ui.Widget)) bool {
        const content = sc.content_size orelse return true;
        const viewport = sc.viewport orelse return true;
        return content.height <= viewport.height or sc.y >= @as(isize, @intCast(content.height - viewport.height));
    }

    fn requestMerge(self: *View) void {
        if (self.session.host_request != null) return;
        const id = self.stack_id orelse return;
        self.session.host_request = .{ .workspace_merge = id };
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }

    pub fn atTop(self: View) bool {
        return self.box.children.values()[frame_index].widget.box.children.values()[0].widget.scroll.y <= 0;
    }

    fn frameBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.box.children.values()[frame_index].widget.box;
    }

    fn contentScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.frameBox().children.values()[0].widget.scroll;
    }

    fn markdownView(self: *View) *Markdown.View {
        return &self.contentScroll().child.markdown;
    }
};
