//! Code block highlighting at build time with tree-sitter (the C library and
//! the official grammars, compiled in build.zig; their `highlights.scm`
//! queries embedded). The Rust wiki used syntect with bat's Sublime syntaxes;
//! there is no Zig syntect, so the token classes differ: a capture such as
//! `@function.method` becomes `<span class="hl-function hl-function-method">`
//! inside `<span class="hl-source hl-<lang>">`, and `css()` styles them with
//! the colours of the themes the Rust wiki used (InspiredGitHub light,
//! base16-ocean dark). Code in a language without a grammar is written the
//! way syntect writes plain text (one `hl-text hl-plain` span).
//!
//! Overlapping captures are resolved per byte, like tree-sitter-highlight:
//! the narrowest capture wins, and on the same node the grammar's own
//! precedence (first pattern for tree-sitter/*, last for the
//! nvim-style tree-sitter-grammars/* queries). Predicates #eq?, #not-eq?,
//! #match?, #not-match?, #lua-match? and #any-of? are evaluated; others
//! (#set!, #is-not? local) are ignored. Injections are not run.
const std = @import("std");
const Regex = @import("regex");
const Allocator = std.mem.Allocator;
const Out = std.ArrayList(u8);

pub const prefix = "hl-";

// ------------------------------------------------------------------ C API

const TSLanguage = opaque {};
const TSParser = opaque {};
const TSTree = opaque {};
const TSQuery = opaque {};
const TSQueryCursor = opaque {};
const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};
const TSQueryCapture = extern struct {
    node: TSNode,
    index: u32,
};
const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const TSQueryCapture,
};
const TSQueryPredicateStep = extern struct {
    type: enum(c_uint) { done = 0, capture = 1, string = 2 },
    value_id: u32,
};

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(parser: *TSParser) void;
extern fn ts_parser_set_language(parser: *TSParser, language: *const TSLanguage) bool;
extern fn ts_parser_parse_string(parser: *TSParser, old_tree: ?*const TSTree, string: [*]const u8, length: u32) ?*TSTree;
extern fn ts_tree_delete(tree: *TSTree) void;
extern fn ts_tree_root_node(tree: *const TSTree) TSNode;
extern fn ts_node_start_byte(node: TSNode) u32;
extern fn ts_node_end_byte(node: TSNode) u32;
extern fn ts_query_new(language: *const TSLanguage, source: [*]const u8, source_len: u32, error_offset: *u32, error_type: *c_uint) ?*TSQuery;
extern fn ts_query_delete(query: *TSQuery) void;
extern fn ts_query_capture_name_for_id(query: *const TSQuery, index: u32, length: *u32) [*]const u8;
extern fn ts_query_string_value_for_id(query: *const TSQuery, index: u32, length: *u32) [*]const u8;
extern fn ts_query_predicates_for_pattern(query: *const TSQuery, pattern_index: u32, step_count: *u32) [*]const TSQueryPredicateStep;
extern fn ts_query_cursor_new() ?*TSQueryCursor;
extern fn ts_query_cursor_delete(cursor: *TSQueryCursor) void;
extern fn ts_query_cursor_exec(cursor: *TSQueryCursor, query: *const TSQuery, node: TSNode) void;
extern fn ts_query_cursor_next_match(cursor: *TSQueryCursor, match: *TSQueryMatch) bool;

extern fn tree_sitter_bash() *const TSLanguage;
extern fn tree_sitter_json() *const TSLanguage;
extern fn tree_sitter_rust() *const TSLanguage;
extern fn tree_sitter_python() *const TSLanguage;
extern fn tree_sitter_javascript() *const TSLanguage;
extern fn tree_sitter_yaml() *const TSLanguage;
extern fn tree_sitter_toml() *const TSLanguage;
extern fn tree_sitter_zig() *const TSLanguage;
extern fn tree_sitter_lua() *const TSLanguage;
extern fn tree_sitter_diff() *const TSLanguage;

// ---------------------------------------------------------------- grammars

const Grammar = struct {
    /// class suffix of the wrapper span, like syntect's scope (`hl-source hl-rust`)
    name: []const u8,
    /// fenced code info strings that pick it
    tokens: []const []const u8,
    language: *const fn () callconv(.c) *const TSLanguage,
    highlights: []const u8,
    /// on the same node, the last pattern wins (nvim-style queries)
    last_wins: bool,
};

const grammars = [_]Grammar{
    .{ .name = "shell", .tokens = &.{ "sh", "bash", "shell", "zsh", "console", "shell-session", "ksh" }, .language = tree_sitter_bash, .highlights = @embedFile("ts_bash_highlights"), .last_wins = false },
    .{ .name = "json", .tokens = &.{ "json", "jsonc", "json5", "geojson" }, .language = tree_sitter_json, .highlights = @embedFile("ts_json_highlights"), .last_wins = false },
    .{ .name = "rust", .tokens = &.{ "rust", "rs" }, .language = tree_sitter_rust, .highlights = @embedFile("ts_rust_highlights"), .last_wins = false },
    .{ .name = "python", .tokens = &.{ "python", "py", "python3" }, .language = tree_sitter_python, .highlights = @embedFile("ts_python_highlights"), .last_wins = false },
    .{ .name = "js", .tokens = &.{ "javascript", "js", "mjs", "cjs", "jsx" }, .language = tree_sitter_javascript, .highlights = @embedFile("ts_javascript_highlights"), .last_wins = false },
    .{ .name = "yaml", .tokens = &.{ "yaml", "yml" }, .language = tree_sitter_yaml, .highlights = @embedFile("ts_yaml_highlights"), .last_wins = true },
    .{ .name = "toml", .tokens = &.{"toml"}, .language = tree_sitter_toml, .highlights = @embedFile("ts_toml_highlights"), .last_wins = true },
    .{ .name = "zig", .tokens = &.{ "zig", "zon" }, .language = tree_sitter_zig, .highlights = @embedFile("ts_zig_highlights"), .last_wins = true },
    .{ .name = "lua", .tokens = &.{"lua"}, .language = tree_sitter_lua, .highlights = @embedFile("ts_lua_highlights"), .last_wins = true },
    .{ .name = "diff", .tokens = &.{ "diff", "patch" }, .language = tree_sitter_diff, .highlights = @embedFile("ts_diff_highlights"), .last_wins = true },
};

fn findGrammar(lang: []const u8) ?usize {
    // `rust,no_run` and the like
    const token = if (std.mem.indexOfScalar(u8, lang, ',')) |at| lang[0..at] else lang;
    for (grammars, 0..) |g, i| for (g.tokens) |t| if (std.ascii.eqlIgnoreCase(t, token)) return i;
    return null;
}

/// Compiled queries, one per grammar, built on first use and kept for the
/// process (the server rebuilds the site many times).
var queries: [grammars.len]?*TSQuery = @splat(null);
var queries_mutex: std.Io.Mutex = .init;

fn query(index: usize) ?*TSQuery {
    queries_mutex.lockUncancelable(std.Options.debug_io);
    defer queries_mutex.unlock(std.Options.debug_io);
    if (queries[index]) |q| return q;
    const g = grammars[index];
    var offset: u32 = 0;
    var kind: c_uint = 0;
    const q = ts_query_new(g.language(), g.highlights.ptr, @intCast(g.highlights.len), &offset, &kind) orelse {
        std.debug.print("wiki: {s} highlights.scm: query error {d} at byte {d}\n", .{ g.name, kind, offset });
        return null;
    };
    queries[index] = q;
    return q;
}

// ---------------------------------------------------------------- writing

pub fn write(arena: Allocator, out: *Out, lang: []const u8, code: []const u8) !void {
    if (findGrammar(lang)) |index| {
        if (highlightInto(arena, out, index, code)) |ok| {
            if (ok) return;
        } else |err| return err;
    }
    try out.appendSlice(arena, "<span class=\"hl-text hl-plain\">");
    try escape(arena, out, code);
    try out.appendSlice(arena, "</span>");
}

const Owner = struct {
    capture: u32,
    len: u32,
    pattern: u32,
};

/// false when the code couldn't be parsed (then it is written as plain text).
fn highlightInto(arena: Allocator, out: *Out, index: usize, code: []const u8) !bool {
    if (code.len == 0 or code.len > std.math.maxInt(u32)) return false;
    const g = grammars[index];
    const q = query(index) orelse return false;
    const parser = ts_parser_new() orelse return false;
    defer ts_parser_delete(parser);
    if (!ts_parser_set_language(parser, g.language())) return false;
    const tree = ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return false;
    defer ts_tree_delete(tree);
    const cursor = ts_query_cursor_new() orelse return false;
    defer ts_query_cursor_delete(cursor);
    ts_query_cursor_exec(cursor, q, ts_tree_root_node(tree));

    const none = std.math.maxInt(u32);
    const owners = try arena.alloc(Owner, code.len);
    @memset(owners, .{ .capture = none, .len = none, .pattern = 0 });
    var regexes: std.StringHashMapUnmanaged(?Regex) = .empty;
    defer {
        var it = regexes.valueIterator();
        while (it.next()) |r| if (r.*) |*re| re.deinit();
    }
    var m: TSQueryMatch = undefined;
    while (ts_query_cursor_next_match(cursor, &m)) {
        if (!try predicatesHold(arena, q, &m, code, &regexes)) continue;
        for (m.captures[0..m.capture_count]) |cap| {
            var name_len: u32 = 0;
            const name = ts_query_capture_name_for_id(q, cap.index, &name_len)[0..name_len];
            // `_private` captures only feed predicates; `none`/`spell` style nothing
            if (name.len == 0 or name[0] == '_' or std.mem.eql(u8, name, "spell") or std.mem.eql(u8, name, "nospell") or std.mem.eql(u8, name, "none")) continue;
            const start = ts_node_start_byte(cap.node);
            const end = @min(ts_node_end_byte(cap.node), @as(u32, @intCast(code.len)));
            if (end <= start) continue;
            const len = end - start;
            for (owners[start..end]) |*o| {
                const better = len < o.len or (len == o.len and (if (g.last_wins) m.pattern_index >= o.pattern else m.pattern_index < o.pattern or o.capture == none));
                if (better) o.* = .{ .capture = cap.index, .len = len, .pattern = m.pattern_index };
            }
        }
    }

    try out.print(arena, "<span class=\"hl-source hl-{s}\">", .{g.name});
    var i: usize = 0;
    while (i < code.len) {
        const cap = owners[i].capture;
        var j = i + 1;
        while (j < code.len and owners[j].capture == cap) j += 1;
        if (cap == none) {
            try escape(arena, out, code[i..j]);
        } else {
            var name_len: u32 = 0;
            const name = ts_query_capture_name_for_id(q, cap, &name_len)[0..name_len];
            try out.appendSlice(arena, "<span class=\"");
            try classes(arena, out, name);
            try out.appendSlice(arena, "\">");
            try escape(arena, out, code[i..j]);
            try out.appendSlice(arena, "</span>");
        }
        i = j;
    }
    try out.appendSlice(arena, "</span>");
    return true;
}

/// `function.method` -> `hl-function hl-function-method`
fn classes(arena: Allocator, out: *Out, name: []const u8) !void {
    var end: usize = 0;
    var first = true;
    while (end <= name.len) : (end += 1) {
        if (end == name.len or name[end] == '.') {
            if (!first) try out.append(arena, ' ');
            first = false;
            try out.appendSlice(arena, prefix);
            for (name[0..end]) |ch| try out.append(arena, if (ch == '.') '-' else ch);
        }
    }
}

fn captureText(m: *const TSQueryMatch, id: u32, code: []const u8) ?[]const u8 {
    for (m.captures[0..m.capture_count]) |cap| if (cap.index == id) {
        const s = ts_node_start_byte(cap.node);
        const e = @min(ts_node_end_byte(cap.node), @as(u32, @intCast(code.len)));
        return if (e >= s) code[s..e] else "";
    };
    return null;
}

fn predicatesHold(arena: Allocator, q: *const TSQuery, m: *const TSQueryMatch, code: []const u8, regexes: *std.StringHashMapUnmanaged(?Regex)) !bool {
    var count: u32 = 0;
    const steps = ts_query_predicates_for_pattern(q, m.pattern_index, &count)[0..count];
    var i: usize = 0;
    while (i < steps.len) {
        var end = i;
        while (end < steps.len and steps[end].type != .done) end += 1;
        const pred = steps[i..end];
        i = end + 1;
        if (pred.len < 2 or pred[0].type != .string) continue;
        var len: u32 = 0;
        const op = ts_query_string_value_for_id(q, pred[0].value_id, &len)[0..len];
        if (pred[1].type != .capture) continue;
        // a predicate on a capture this match lacks (quantified) holds
        const text = captureText(m, pred[1].value_id, code) orelse continue;
        const negate = std.mem.startsWith(u8, op, "not-");
        const base = if (negate) op[4..] else op;
        const holds: bool = blk: {
            if (std.mem.eql(u8, base, "eq?") and pred.len >= 3) {
                const other = if (pred[2].type == .capture) captureText(m, pred[2].value_id, code) orelse "" else str(q, pred[2].value_id);
                break :blk std.mem.eql(u8, text, other);
            } else if ((std.mem.eql(u8, base, "match?") or std.mem.eql(u8, base, "lua-match?")) and pred.len >= 3 and pred[2].type == .string) {
                var pattern = str(q, pred[2].value_id);
                if (std.mem.eql(u8, base, "lua-match?")) pattern = try luaToRegex(arena, pattern);
                const gop = try regexes.getOrPut(arena, pattern);
                if (!gop.found_existing) {
                    gop.value_ptr.* = Regex.compile(arena, pattern, .{}) catch null;
                }
                if (gop.value_ptr.*) |*re| break :blk re.match(text);
                break :blk true;
            } else if (std.mem.eql(u8, base, "any-of?")) {
                for (pred[2..]) |step| if (step.type == .string and std.mem.eql(u8, str(q, step.value_id), text)) break :blk true;
                break :blk false;
            }
            continue; // unknown predicates hold
        };
        if (holds == negate) return false;
    }
    return true;
}

fn str(q: *const TSQuery, id: u32) []const u8 {
    var len: u32 = 0;
    return ts_query_string_value_for_id(q, id, &len)[0..len];
}

/// The Lua pattern classes nvim queries use, as a regex.
fn luaToRegex(arena: Allocator, pattern: []const u8) ![]const u8 {
    var out: Out = .empty;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '%' and i + 1 < pattern.len) {
            i += 1;
            try out.appendSlice(arena, switch (pattern[i]) {
                'a' => "[A-Za-z]",
                'd' => "[0-9]",
                'l' => "[a-z]",
                'u' => "[A-Z]",
                'w' => "[A-Za-z0-9]",
                's' => "\\s",
                'p' => "[[:punct:]]",
                'x' => "[0-9A-Fa-f]",
                else => &.{ '\\', pattern[i] },
            });
        } else try out.append(arena, pattern[i]);
    }
    return out.items;
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

/// CSS for the highlight classes, appended to the bundled style.css, in the
/// colours of syntect's InspiredGitHub (light) and base16-ocean.dark themes.
pub fn css(arena: Allocator) ![]const u8 {
    _ = arena;
    return 
    \\
    \\@media (prefers-color-scheme: light) {
    \\.hl-comment { color: #969896; font-style: italic; }
    \\.hl-string, .hl-character { color: #183691; }
    \\.hl-string-escape, .hl-escape, .hl-string-special, .hl-string-regexp { color: #183691; font-weight: bold; }
    \\.hl-keyword, .hl-conditional, .hl-repeat, .hl-include, .hl-exception, .hl-storageclass { color: #a71d5d; }
    \\.hl-operator { color: #a71d5d; }
    \\.hl-number, .hl-float, .hl-boolean, .hl-constant, .hl-constant-builtin { color: #0086b3; }
    \\.hl-function, .hl-function-call, .hl-function-method, .hl-method, .hl-constructor { color: #795da3; }
    \\.hl-function-builtin, .hl-variable-builtin, .hl-module, .hl-namespace { color: #0086b3; }
    \\.hl-type, .hl-type-builtin, .hl-label { color: #0086b3; }
    \\.hl-property, .hl-field, .hl-attribute, .hl-tag { color: #63a35c; }
    \\.hl-variable-parameter, .hl-parameter { color: #333333; }
    \\.hl-punctuation { color: #333333; }
    \\.hl-diff-plus, .hl-addition, .hl-string-addition { color: #55a532; background-color: #eaffea; }
    \\.hl-diff-minus, .hl-deletion, .hl-string-deletion { color: #bd2c00; background-color: #ffecec; }
    \\.hl-attribute-diff, .hl-function-diff { color: #795da3; }
    \\}
    \\@media (prefers-color-scheme: dark) {
    \\.hl-comment { color: #65737e; }
    \\.hl-string, .hl-character { color: #a3be8c; }
    \\.hl-string-escape, .hl-escape, .hl-string-special, .hl-string-regexp { color: #96b5b4; }
    \\.hl-keyword, .hl-conditional, .hl-repeat, .hl-include, .hl-exception, .hl-storageclass { color: #b48ead; }
    \\.hl-operator, .hl-punctuation { color: #c0c5ce; }
    \\.hl-number, .hl-float, .hl-boolean, .hl-constant, .hl-constant-builtin { color: #d08770; }
    \\.hl-function, .hl-function-call, .hl-function-method, .hl-method, .hl-constructor { color: #8fa1b3; }
    \\.hl-function-builtin, .hl-variable-builtin, .hl-module, .hl-namespace { color: #96b5b4; }
    \\.hl-type, .hl-type-builtin, .hl-label { color: #ebcb8b; }
    \\.hl-property, .hl-field, .hl-tag { color: #bf616a; }
    \\.hl-attribute { color: #d08770; }
    \\.hl-variable-parameter, .hl-parameter { color: #c0c5ce; }
    \\.hl-diff-plus, .hl-addition, .hl-string-addition { color: #a3be8c; }
    \\.hl-diff-minus, .hl-deletion, .hl-string-deletion { color: #bf616a; }
    \\.hl-attribute-diff, .hl-function-diff { color: #8fa1b3; }
    \\}
    \\
    ;
}

test "highlight" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: Out = .empty;
    try write(a, &out, "rust", "fn main() { let x = \"hi\"; } // c\n");
    try std.testing.expect(std.mem.startsWith(u8, out.items, "<span class=\"hl-source hl-rust\">"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<span class=\"hl-keyword\">fn</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hl-comment") != null);
    out = .empty;
    try write(a, &out, "", "a < b\n");
    try std.testing.expectEqualStrings("<span class=\"hl-text hl-plain\">a &lt; b\n</span>", out.items);
    out = .empty;
    try write(a, &out, "sh", "echo 'x' # y\n");
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hl-comment") != null);
}
