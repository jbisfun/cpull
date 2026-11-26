// filing a cpull report from the web UI: the files view's "report this line"
// form posts the file, the line and the ref it shows (web.zig's local `report`
// route), and the report is an issue anchored at that line of that commit,
// like `cpull report add` files one from the work tree (report.zig).
const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const report = @import("report.zig");
const anchor_mod = @import("anchor.zig");

pub const New = struct {
    // the path in the repo
    file: []const u8,
    line: u64,
    // the ref the files view showed, as its route holds it (null = the
    // default branch; branch and tag names url-encoded)
    ref_kind: ?ui.RoutablePage.RefOrOid = null,
    ref_value: []const u8 = "",
    note: []const u8 = "",
    title: ?[]const u8 = null,
    quote: ?[]const u8 = null,
    labels: []const u8 = "",
};

// file the report in the repo `source` names; returns the new issue's id
pub fn file(io: std.Io, gpa: std.mem.Allocator, source: ui.RepoSource, author: evt.CommitAuthor, new: New) ![evt.event_id_size * 2]u8 {
    if (new.line == 0) return error.InvalidLineNumber;
    if (new.file.len == 0 or std.mem.startsWith(u8, new.file, "/")) return error.InvalidPath;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var id_bytes: [evt.event_id_size]u8 = undefined;
    io.random(&id_bytes);
    const id = std.fmt.bytesToHex(id_bytes, .lower);
    const note = std.mem.trim(u8, new.note, " \t\r\n");
    const title = try report.deriveTitle(aa, new.title, note, new.file, new.line);
    var labels: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, new.labels, " ,");
    while (it.next()) |l| if (!std.mem.eql(u8, l, report.label)) {
        try labels.appendSlice(aa, l);
        try labels.append(aa, ' ');
    };
    try labels.appendSlice(aa, report.label);

    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    const opts = repo.self_repo_opts;
                    const resolved = (try ui.ResolvedRefOrOid(repo_kind, opts).init(repo, io, aa, new.ref_kind, new.ref_value)) orelse return error.RefNotFound;
                    const lines = try anchor_mod.readFile(repo_kind, opts, repo, io, &arena, &resolved.oid, new.file);
                    if (new.line > lines.len) return error.InvalidLineNumber;
                    const line_text = lines[new.line - 1];
                    const quote: ?[]const u8 = if (new.quote) |q| blk: {
                        const trimmed = std.mem.trim(u8, q, " \t\r\n");
                        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, std.mem.trim(u8, line_text, " \t\r"))) break :blk null;
                        break :blk trimmed;
                    } else null;
                    const issue: evt.Issue = .{
                        .title = title,
                        .description = note,
                        .labels = labels.items,
                        .anchor = .{ .file = new.file, .line = new.line, .line_text = line_text, .quote = quote, .commit = &resolved.oid, .source = "web" },
                    };
                    try evt.consume(.local, .repo, repo_kind, opts, io, gpa, repo, evt.events_ref, &.{.{
                        .id = id,
                        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
                        .author = author,
                        .event = .{ .issue = issue },
                    }});
                },
            }
        },
    }
    return id;
}
