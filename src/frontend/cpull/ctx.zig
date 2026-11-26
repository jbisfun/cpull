// what every cpull view builds its template data with: the page arena, the
// session, and helpers turning cpull's routes, times and authors into strings.
const std = @import("std");
const ui = @import("../../ui.zig");
const evt = @import("../../event.zig");
const theme = @import("../theme/theme.zig");
const localtime = @import("localtime.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    session: *const ui.Session.Data,

    pub fn aa(c: Ctx) std.mem.Allocator {
        return c.arena.allocator();
    }

    pub fn server(c: Ctx) bool {
        return c.session.host_kind == .server;
    }

    // a pull workspace in local mode
    pub fn workspace(c: Ctx) ?[]const u8 {
        return c.session.workspace;
    }

    pub fn print(c: Ctx, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return c.aa().print(fmt, args);
    }

    pub fn url(c: Ctx, route: ui.RoutablePage) ![]const u8 {
        return route.toUrl(c.arena);
    }

    // a route built by one of cpull's builders, which return null when it doesn't fit
    pub fn routeUrl(c: Ctx, route: ?ui.RoutablePage) ![]const u8 {
        return c.url(route orelse return error.RouteTooLong);
    }

    // a url-encoded route value as text
    pub fn decode(c: Ctx, encoded: []const u8) ![]const u8 {
        return std.Uri.percentDecodeInPlace(try c.aa().dupe(u8, encoded));
    }

    pub fn time(c: Ctx, secs: i64) !theme.Time {
        const text = try ui.timestamp.format(c.aa(), secs, c.session.now);
        if (secs < 0) return .{ .relative = text.relative, .exact = text.exact };
        return .{
            .relative = text.relative,
            .exact = text.exact,
            .local = (try localtime.format(c.aa(), secs)) orelse "",
            .utc = try localtime.utc(c.aa(), @intCast(secs)),
        };
    }

    // the failed form retained for this page, when it is of kind `tag`
    pub fn feedback(c: Ctx, comptime tag: std.meta.Tag(ui.Session.FormFeedback)) ?@FieldType(ui.Session.FormFeedback, @tagName(tag)) {
        const f = c.session.form_feedback orelse return null;
        return if (f == tag) @field(f, @tagName(tag)) else null;
    }

    // the url of user `name`'s page (server mode)
    pub fn userUrl(c: Ctx, name: []const u8) ![]const u8 {
        const parsed = ui.RoutablePage.Array(evt.User.name_max_len).from(name) orelse return error.RouteTooLong;
        return c.url(.{ .user_repos = .{ .name = parsed } });
    }

    // a repo's identicon, from its cpull repo name (see repoIconName)
    pub fn repoAvatar(c: Ctx, name: []const u8, class: []const u8) !theme.vin.Str {
        return theme.avatar(c.aa(), try repoIconName(c.aa(), name), class);
    }

    pub fn author(c: Ctx, value: ui.Author) !Person {
        return switch (value) {
            .unknown => .{ .name = "someone" },
            .email => |email| .{ .name = email },
            .user_name => |name| .{ .name = name, .href = if (c.server()) try c.userUrl(name) else "" },
        };
    }
};

// who wrote something: a name, linking to their page when they have one
pub const Person = struct {
    name: []const u8,
    href: []const u8 = "",
};

// the name a repo's identicon is drawn from, the same one /<repo>/icon.svg
// uses: the cpull repo name, i.e. an "owner:name" identity's name, with a
// nested pullfile repo's "group/name" as the "group.name" its identity holds
pub fn repoIconName(arena: std.mem.Allocator, name_or_identity: []const u8) ![]const u8 {
    const name = if (std.mem.lastIndexOfScalar(u8, name_or_identity, ':')) |i| name_or_identity[i + 1 ..] else name_or_identity;
    if (std.mem.indexOfScalar(u8, name, '/') == null) return name;
    const key = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, key, '/', '.');
    return key;
}

pub fn short(oid: []const u8) []const u8 {
    return oid[0..@min(oid.len, 10)];
}

pub fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

// a message's first line
pub fn summary(message: []const u8) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, message, '\n')) |nl| std.mem.trimEnd(u8, message[0..nl], " \t\r") else message;
    return if (line.len == 0) "(no message)" else line;
}

pub fn seconds(timestamp: u64) i64 {
    return std.math.cast(i64, timestamp) orelse -1;
}

// space-separated labels as a list
pub fn labels(c: Ctx, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |label| try list.append(c.aa(), label);
    return list.items;
}
