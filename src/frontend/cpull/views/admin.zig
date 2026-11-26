// a repo's owner pages on the server: the settings with their members,
// branches and delete sub tabs (ui/Repo/Settings.zig), and the undo history
// (ui/Repo/Undo.zig). Every form posts to the route web.zig handles for the
// terminal UI's matching form, so no javascript is involved.
const std = @import("std");
const ui = @import("../../../ui.zig");
const evt = @import("../../../event.zig");
const theme = @import("theme");
const fe = @import("../frontend.zig");
const ctx = @import("../ctx.zig");
const repo_views = @import("repo.zig");
const Ctx = ctx.Ctx;
const Repo = ui.Repo;
const RoutablePage = ui.RoutablePage;
const Settings = Repo.Settings;

const Option = struct { value: []const u8, label: []const u8, selected: bool };
const RoleField = struct { name: []const u8, label: []const u8, options: []const Option };
const Member = struct {
    name: []const u8,
    href: []const u8,
    role: []const u8,
    // a form posting to the row's url plus /promote, or a link asking first
    promote_action: []const u8 = "",
    demote_href: []const u8 = "",
    revoke_href: []const u8,
};
const Branch = struct { name: []const u8, href: []const u8, unprotect_action: []const u8 };
const Confirm = struct { text: []const u8, action: []const u8, submit: []const u8, back: []const u8 };

// the role choices in the order the terminal UI's form shows them
const role_choices = [_]?evt.Repo.Role{ null, .write, .read };

pub fn settings(c: Ctx, w: *std.Io.Writer, data: *const Repo) !void {
    const s = &(data.settings orelse return error.NotFound);
    const aa = c.aa();
    const id = s.identity;
    const tabs = try aa.dupe(theme.Link, &.{
        .{ .label = "Settings", .href = try c.routeUrl(RoutablePage.repoSettingsRoute(id)), .active = s.view == .settings },
        .{ .label = "Members", .href = try c.routeUrl(RoutablePage.repoMembersRoute(id, 0)), .active = s.view == .members },
        .{ .label = "Branches", .href = try c.routeUrl(RoutablePage.repoBranchesRoute(id)), .active = s.view == .branches },
    });
    var tab_list: std.ArrayList(theme.Link) = .fromOwnedSlice(tabs);
    if (s.delete != null) try tab_list.append(aa, .{ .label = "Delete", .href = try c.routeUrl(RoutablePage.repoDeleteRoute(id)), .active = s.view == .delete });

    const view_name = @tagName(s.view);
    var error_text: []const u8 = "";
    var form: struct {
        name: []const u8 = "",
        description: []const u8 = "",
        access: []const Option = &.{},
        roles: []const RoleField = &.{},
        hash: []const u8 = "",
    } = .{};
    var members: []const Member = &.{};
    var members_prev: []const u8 = "";
    var members_next: []const u8 = "";
    var confirm: ?Confirm = null;
    var add_value: []const u8 = "";
    var branches: []const Branch = &.{};
    var default_value: []const u8 = "";
    var delete_confirm_text: []const u8 = "";
    var delete_typed: []const u8 = "";
    const page_url = try c.url(c.session.current_page);

    switch (s.view) {
        .settings => {
            const saved = c.feedback(.repo_settings);
            const Fields = @FieldType(@FieldType(ui.Session.FormFeedback, "repo_settings"), "fields");
            const fields: Fields = if (saved) |f| f.fields else .{ .name = s.name, .description = s.description, .access = s.access, .discuss_role = s.discuss_role, .issue_role = s.issue_role, .patch_role = s.patch_role };
            if (saved) |f| error_text = switch (f.failure) {
                .required_name => "Enter a name.",
                .invalid_name => "A name holds letters, digits, '-', '_' and '.', up to 100 of them.",
                .name_taken => "You already have a repository by that name.",
                .invalid_copy => "That repository can't be copied.",
            };
            var access: std.ArrayList(Option) = .empty;
            for (std.enums.values(evt.Repo.Access)) |value| try access.append(aa, .{ .value = @tagName(value), .label = if (value == .public) "Public: anybody can read it" else "Private: only its members can read it", .selected = value == fields.access });
            var roles: std.ArrayList(RoleField) = .empty;
            for ([_][]const u8{ "discuss_role", "issue_role", "patch_role" }, [_][]const u8{ "Who can start discussions", "Who can open issues", "Who can propose patches" }, [_]?evt.Repo.Role{ fields.discuss_role, fields.issue_role, fields.patch_role }) |name, label, current| {
                var options: std.ArrayList(Option) = .empty;
                for (role_choices) |role| {
                    const role_label = Settings.roleLabel(role);
                    try options.append(aa, .{ .value = role_label, .label = role_label, .selected = std.mem.eql(u8, role_label, Settings.roleLabel(current)) });
                }
                try roles.append(aa, .{ .name = name, .label = label, .options = options.items });
            }
            form = .{ .name = fields.name, .description = fields.description, .access = access.items, .roles = roles.items, .hash = @tagName(s.hash_kind) };
        },
        .members => {
            const m = &s.members;
            if (m.confirm) |pending| {
                confirm = .{
                    .text = if (pending.action == .demote) try c.print("Make {s} a member instead of an owner? They can still push, but can no longer add or remove members.", .{pending.name}) else try c.print("Remove {s} from this repository? They can no longer push to it.", .{pending.name}),
                    .action = page_url,
                    .submit = if (pending.action == .demote) "Demote to member" else "Remove member",
                    .back = try c.routeUrl(RoutablePage.repoMembersRoute(id, m.start)),
                };
            }
            if (c.feedback(.repo_members)) |f| {
                add_value = f.name;
                error_text = switch (f.failure) {
                    .not_found => "There is no user by that name.",
                    .already_added => "They're already a member.",
                };
            }
            var rows: std.ArrayList(Member) = .empty;
            for (m.rows) |row| {
                const row_url = try rowUrl(c, id, m.start, row.name);
                try rows.append(aa, .{
                    .name = row.name,
                    .href = try c.userUrl(row.name),
                    .role = if (row.role == .owner) "owner" else "member",
                    .promote_action = if (row.role == .owner) "" else try c.print("{s}/promote", .{row_url}),
                    .demote_href = if (row.role == .owner) try confirmUrl(c, id, m.start, row.name, .demote) else "",
                    .revoke_href = try confirmUrl(c, id, m.start, row.name, .revoke),
                });
            }
            members = rows.items;
            if (m.start > 0) members_prev = try c.routeUrl(RoutablePage.repoMembersRoute(id, m.start -| Repo.Members.page_size));
            if (m.next_start) |next| members_next = try c.routeUrl(RoutablePage.repoMembersRoute(id, next));
        },
        .branches => {
            const b = &s.branches;
            default_value = b.default_branch;
            if (c.feedback(.repo_branches)) |f| {
                if (f.default) default_value = f.name else add_value = f.name;
                error_text = switch (f.failure) {
                    .not_found => "There is no branch by that name.",
                    .already_added => "That branch is already protected.",
                    .too_many => "This repository protects as many branches as it can.",
                    .too_long => "That branch name is too long.",
                };
            }
            var rows: std.ArrayList(Branch) = .empty;
            for (b.names) |name| {
                const encoded = try ui.urlEncodeRef(aa, name);
                var route = RoutablePage.repoBranchesRoute(id) orelse return error.RouteTooLong;
                route.repo_branches.branch = RoutablePage.Array(RoutablePage.ref_route_max_len).from(encoded) orelse return error.RouteTooLong;
                try rows.append(aa, .{
                    .name = name,
                    .href = try c.routeUrl(RoutablePage.repoFilesRoute(id, .branch, encoded, "", 0)),
                    .unprotect_action = try c.print("{s}/unprotect", .{try c.url(route)}),
                });
            }
            branches = rows.items;
        },
        .delete => {
            const target = (s.delete orelse return error.NotFound).target;
            delete_confirm_text = target.confirmText();
            if (c.feedback(.delete)) |f| if (f.target == .repo) {
                delete_typed = f.confirm;
                error_text = switch (f.failure) {
                    .wrong_confirm => "What you typed doesn't match the repository's name.",
                    .wrong_password => "That isn't your password.",
                };
            };
        },
    }

    const settings_url = try c.routeUrl(RoutablePage.repoSettingsRoute(id));
    const members_url = try c.routeUrl(RoutablePage.repoMembersRoute(id, if (s.view == .members) s.members.start else 0));
    const branches_url = try c.routeUrl(RoutablePage.repoBranchesRoute(id));
    const delete_url = try c.routeUrl(RoutablePage.repoDeleteRoute(id));
    try fe.emit(c, w, try repo_views.chrome(c, data, "Settings", &.{}), "settings.html", .{
        .view = view_name,
        .tabs = tab_list.items,
        .error_text = error_text,
        .form = form,
        .settings_action = settings_url,
        .members = members,
        .members_prev = members_prev,
        .members_next = members_next,
        .grant_action = try c.print("{s}/grant", .{members_url}),
        .confirm = confirm,
        .add_value = add_value,
        .branches = branches,
        .default_value = default_value,
        .default_action = try c.print("{s}/default", .{branches_url}),
        .protect_action = try c.print("{s}/protect", .{branches_url}),
        .delete_action = try c.print("{s}/delete", .{delete_url}),
        .delete_confirm_text = delete_confirm_text,
        .delete_typed = delete_typed,
    });
}

// a member row's url, which its promote form posts under
fn rowUrl(c: Ctx, id: []const u8, start: usize, name: []const u8) ![]const u8 {
    var route = RoutablePage.repoMembersRoute(id, start) orelse return error.RouteTooLong;
    route.repo_members.user = RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    return c.url(route);
}

// the page asking to take `name`'s role away, which posts to itself
fn confirmUrl(c: Ctx, id: []const u8, start: usize, name: []const u8, action: Repo.Members.Action) ![]const u8 {
    var route = RoutablePage.repoMembersRoute(id, start) orelse return error.RouteTooLong;
    route.repo_members.user = RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
    route.repo_members.confirm = action;
    return c.url(route);
}

// --- undo ----------------------------------------------------------------

const UndoRow = struct {
    index: u64,
    action: []const u8,
    description: []const u8,
    details: []const DetailLink,
    time: theme.Time,
    href: []const u8,
    // the undo form's action; empty when the row can't be undone
    form: []const u8,
    label: []const u8,
    undone: bool,
    selected: bool,
};
const DetailLink = struct { label: []const u8, text: []const u8, href: []const u8 };

pub fn undo(c: Ctx, w: *std.Io.Writer, data: *const Repo) !void {
    const u = &(data.undo orelse return error.NotFound);
    const aa = c.aa();
    const selected_index: ?u64 = switch (c.session.current_page) {
        .repo_undo => |r| r.index,
        else => null,
    };
    var rows: std.ArrayList(UndoRow) = .empty;
    for (u.items) |item| {
        var details: std.ArrayList(DetailLink) = .empty;
        for (item.buttons) |b| try details.append(aa, .{ .label = std.mem.trim(u8, b.label, " "), .text = b.text, .href = if (b.link) |link| stripPrefix(link) else "" });
        const enabled = u.handle.canUndo() and item.index > 0;
        try rows.append(aa, .{
            .index = item.index,
            .action = item.action,
            .description = item.description,
            .details = details.items,
            .time = try c.time(item.timestamp),
            .href = stripPrefix(item.link),
            .form = if (enabled and !item.undone) stripPrefix(item.form) else "",
            .label = if (item.index == 0) "Initial state" else if (item.index == u.count - 1) "Undo this" else "Undo this and all above it",
            .undone = item.undone,
            .selected = if (selected_index) |i| i == item.index else false,
        });
    }
    try fe.emit(c, w, try repo_views.chrome(c, data, "Undo", &.{}), "undo.html", .{
        .count = u.count,
        .rows = rows.items,
        .failure = c.session.undo_failure orelse u.failure orelse "",
        .next = if (u.next) |index| try c.routeUrl(RoutablePage.repoUndoRoute(u.identity, index)) else "",
        .first = if (selected_index != null) try c.routeUrl(RoutablePage.repoUndoRoute(u.identity, null)) else "",
    });
}

// the terminal UI's link kinds ("a:", "ai:", "form:") wrap plain urls
fn stripPrefix(link: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, link, ':') orelse return link;
    const slash = std.mem.indexOfScalar(u8, link, '/') orelse return link;
    return if (colon < slash) link[colon + 1 ..] else link;
}

test stripPrefix {
    try std.testing.expectEqualStrings("/a:b/undo", stripPrefix("form:/a:b/undo"));
    try std.testing.expectEqualStrings("/a:b", stripPrefix("ai:/a:b"));
    try std.testing.expectEqualStrings("/a:b", stripPrefix("/a:b"));
}
