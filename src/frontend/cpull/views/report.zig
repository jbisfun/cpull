// cpull reports (line-anchored issues, see src/report/) in the themed UI: the
// anchored code on an issue's page, and the flags on the files view's lines.
const std = @import("std");
const ui = @import("../../../ui.zig");
const evt = @import("../../../event.zig");
const ctx = @import("../ctx.zig");
const anchor_mod = @import("../../../report/anchor.zig");
const Ctx = ctx.Ctx;
const RoutablePage = ui.RoutablePage;

const ExcerptLine = struct { number: u64, text: []const u8, hit: bool };

pub const AnchorView = struct {
    location: []const u8,
    file_href: []const u8,
    line_text: []const u8,
    quote: []const u8,
    source: []const u8,
    commit: []const u8,
    commit_href: []const u8,
    // where the excerpt was read, and whether the line moved or changed since
    note: []const u8,
    changed: bool,
    lines: []const ExcerptLine,
};

// the files view's url for `path` at `line` in a ref, scrolled to the line.
// the view shows the first 5000 lines, so a line past those starts the window
// a little above it.
fn fileHref(c: Ctx, identity: []const u8, ref_kind: RoutablePage.RefOrOid, ref_value: []const u8, path: []const u8, line: u64) ![]const u8 {
    const window: usize = if (line > 4000) @intCast(line - 20) else 0;
    return c.print("{s}#L{d}", .{ try c.routeUrl(RoutablePage.repoFilesRoute(identity, ref_kind, ref_value, path, window)), line });
}

pub fn anchorView(c: Ctx, identity: []const u8, anchor_maybe: ?evt.Issue.Anchor, excerpt_maybe: ?anchor_mod.Excerpt) !?AnchorView {
    const anchor = anchor_maybe orelse return null;
    const aa = c.aa();
    var lines: std.ArrayList(ExcerptLine) = .empty;
    var note: []const u8 = "";
    var changed = false;
    // without an excerpt the file isn't at the head, so link the repo's files
    var file_href = try c.routeUrl(RoutablePage.repoFilesRoute(identity, null, "", "", 0));
    if (excerpt_maybe) |ex| {
        for (ex.lines, 0..) |text, i| {
            const number = ex.first + i;
            try lines.append(aa, .{ .number = number, .text = text, .hit = number == ex.line });
        }
        changed = ex.changed;
        file_href = try fileHref(c, identity, ex.ref_kind, ex.ref_value, anchor.file, ex.line);
        if (ex.at_filed_commit) {
            note = try c.print("At {s}, the commit it was filed against.", .{ctx.short(ex.commit)});
        } else if (ex.changed) {
            note = "The line no longer reads as it did when this was filed; showing the current file around its old line number.";
        } else if (ex.line != ex.filed_line) {
            note = try c.print("The line has moved: it was line {d} when filed and is line {d} now.", .{ ex.filed_line, ex.line });
        } else note = "In the current file.";
    } else note = "The file isn't in the repo's current commit, so only the filed line is shown.";
    return .{
        .location = try c.print("{s}:{d}", .{ anchor.file, anchor.line }),
        .file_href = file_href,
        .line_text = anchor.line_text,
        .quote = anchor.quote orelse "",
        .source = anchor.source orelse "",
        .commit = if (anchor.commit) |oid| ctx.short(oid) else "",
        .commit_href = if (anchor.commit) |oid| try c.routeUrl(RoutablePage.repoFilesRoute(identity, .object, oid, "", 0)) else "",
        .note = note,
        .changed = changed,
        .lines = lines.items,
    };
}

// one open report on the viewed file
pub const Marker = struct {
    // where it points now (relocated within the shown window when the text moved)
    line: u64,
    title: []const u8,
    href: []const u8,
    short_id: []const u8,
};

// the reports on `path`, with each line found again in the shown window when
// it has moved since it was filed
pub fn markers(c: Ctx, identity: []const u8, anchors: []const anchor_mod.FileAnchor, path: []const u8, lines: []const []const u8, window_start: usize) ![]const Marker {
    if (identity.len == 0) return &.{};
    var out: std.ArrayList(Marker) = .empty;
    for (anchors) |a| {
        if (!std.mem.eql(u8, a.file, path)) continue;
        var line = a.line;
        if (line > window_start and line <= window_start + lines.len) {
            if (anchor_mod.relocate(lines, line - window_start, a.line_text)) |found| line = found + window_start;
        }
        try out.append(c.aa(), .{
            .line = line,
            .title = a.title,
            .href = try c.routeUrl(RoutablePage.repoThreadCommentsRoute(.issue, identity, a.id, 0)),
            .short_id = a.id[0..8],
        });
    }
    std.mem.sort(Marker, out.items, {}, struct {
        fn lessThan(_: void, x: Marker, y: Marker) bool {
            return x.line < y.line;
        }
    }.lessThan);
    return out.items;
}

pub fn onLine(c: Ctx, all: []const Marker, line: u64) ![]const Marker {
    var out: std.ArrayList(Marker) = .empty;
    for (all) |m| if (m.line == line) try out.append(c.aa(), m);
    return out.items;
}
