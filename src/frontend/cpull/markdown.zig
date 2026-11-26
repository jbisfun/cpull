// cpull's markdown as html for the templates (ported from hyperhaxy's
// markdown.zig). text is always escaped, so raw html shows as written.
const std = @import("std");
const md = @import("../../markdown.zig");
const theme = @import("theme");

const W = *std.Io.Writer;

pub fn render(arena: std.mem.Allocator, text: []const u8) !theme.vin.Str {
    const doc = try md.parseText(arena, text);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("<div class=\"cpull-prose\">");
    try blocks(&out.writer, doc.blocks);
    try out.writer.writeAll("</div>");
    return theme.markup(out.written());
}

fn esc(w: W, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const entity: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(entity);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

fn blocks(w: W, list: []const md.Block) std.Io.Writer.Error!void {
    for (list) |block| try writeBlock(w, block);
}

fn writeBlock(w: W, block: md.Block) !void {
    switch (block) {
        .heading => |h| {
            // the page owns the h1, so document headings start one level below
            const level = @min(@as(u8, @max(h.level, 1)) + 1, 6);
            try w.print("<h{d}{s}>", .{ level, if (h.center) " class=\"text-center\"" else "" });
            try inlines(w, h.inlines);
            try w.print("</h{d}>", .{level});
        },
        .paragraph => |p| {
            const class: []const u8 = if (p.center and p.pre) " class=\"text-center cpull-pre\"" else if (p.center) " class=\"text-center\"" else if (p.pre) " class=\"cpull-pre\"" else "";
            try w.print("<p{s}>", .{class});
            try inlines(w, p.inlines);
            try w.writeAll("</p>");
        },
        .code, .raw => |lines| {
            try w.writeAll("<pre><code>");
            for (lines, 0..) |line, i| {
                if (i != 0) try w.writeByte('\n');
                try esc(w, line);
            }
            try w.writeAll("</code></pre>");
        },
        .quote => |quoted| {
            try w.writeAll("<blockquote class=\"blockquote\">");
            try blocks(w, quoted);
            try w.writeAll("</blockquote>");
        },
        .list => |l| {
            if (l.ordered) try w.print("<ol start=\"{d}\">", .{l.start}) else try w.writeAll("<ul>");
            for (l.items) |item| {
                if (item.task) |done| {
                    try w.print("<li class=\"list-unstyled\"><input class=\"form-check-input me-1\" type=\"checkbox\" disabled{s}>", .{if (done) " checked" else ""});
                } else try w.writeAll("<li>");
                try blocks(w, item.blocks);
                try w.writeAll("</li>");
            }
            try w.writeAll(if (l.ordered) "</ol>" else "</ul>");
        },
        .rule => try w.writeAll("<hr>"),
    }
}

fn inlines(w: W, runs: []const md.Inline) !void {
    for (runs) |run| {
        const href = if (run.link) |dest| safeLink(dest) else null;
        if (href) |dest| {
            try w.writeAll("<a href=\"");
            try esc(w, dest);
            try w.writeAll("\" rel=\"noreferrer noopener\">");
        }
        if (run.style.strike) try w.writeAll("<s>");
        if (run.style.italic) try w.writeAll("<em>");
        if (run.style.bold) try w.writeAll("<strong>");
        if (run.style.code) try w.writeAll("<code>");
        // hard breaks arrive as newlines inside the text
        var parts = std.mem.splitScalar(u8, run.text, '\n');
        var first = true;
        while (parts.next()) |part| {
            if (!first) try w.writeAll("<br>");
            first = false;
            try esc(w, part);
        }
        if (run.style.code) try w.writeAll("</code>");
        if (run.style.bold) try w.writeAll("</strong>");
        if (run.style.italic) try w.writeAll("</em>");
        if (run.style.strike) try w.writeAll("</s>");
        if (href != null) try w.writeAll("</a>");
    }
}

// only web, mail and same-site links become links
fn safeLink(dest: []const u8) ?[]const u8 {
    for ([_][]const u8{ "http:", "https:", "mailto:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(dest, scheme)) return dest;
    }
    if (std.mem.startsWith(u8, dest, "/") and !std.mem.startsWith(u8, dest, "//")) return dest;
    return null;
}
