//! Code block highlighting. Without a grammar for the block's language the
//! code is written the way syntect writes plain text (one
//! `hl-text hl-plain` span), so the markup matches the Rust wiki's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Out = std.ArrayList(u8);

pub const prefix = "hl-";

pub fn write(arena: Allocator, out: *Out, lang: []const u8, code: []const u8) !void {
    _ = lang;
    try out.appendSlice(arena, "<span class=\"hl-text hl-plain\">");
    try escape(arena, out, code);
    try out.appendSlice(arena, "</span>");
}

/// syntect's html escaping.
pub fn escape(arena: Allocator, out: *Out, s: []const u8) !void {
    var last: usize = 0;
    for (s, 0..) |ch, i| {
        const esc: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try out.appendSlice(arena, s[last..i]);
        try out.appendSlice(arena, esc);
        last = i + 1;
    }
    try out.appendSlice(arena, s[last..]);
}

/// CSS for the highlight classes, appended to the bundled style.css.
pub fn css(arena: Allocator) ![]const u8 {
    _ = arena;
    return "";
}
