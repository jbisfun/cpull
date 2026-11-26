//! Code block highlighting at build time with tree-sitter (the C library and
//! the official grammars, compiled in build.zig; their `highlights.scm`
//! queries embedded), written the way the Rust wiki's syntect wrote it so the
//! site looks the same: each token is a span of TextMate scope classes
//! (`<span class="hl-keyword hl-control hl-rust">`) inside the language's
//! scope (`<span class="hl-source hl-rust">`), and the stylesheet is syntect's
//! own CSS for those classes (highlight.css: InspiredGitHub light,
//! base16-ocean.dark, as `css_for_theme_with_class_style` printed it).
//!
//! tree-sitter captures (`@function.method`) are mapped to the scope syntect's
//! (bat's) syntax gave the same token: `scopes` below, then per-grammar
//! `rules` that can also look at the node's kind, its parent's kind and its
//! text. A function, method or property inside a call expression is looked up
//! as `<capture>.call` first, since syntect tells calls from definitions.
//! Strings get syntect's `punctuation.definition.string.begin/end` around
//! their quotes. The mapping was tuned by comparing every code block of the
//! last Rust-built site, char by char, under that CSS. Code in a language
//! without a grammar is written the way syntect writes plain text (one
//! `hl-text hl-plain` span).
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
extern fn ts_node_type(node: TSNode) [*:0]const u8;
extern fn ts_node_parent(node: TSNode) TSNode;
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
extern fn tree_sitter_c() *const TSLanguage;
extern fn tree_sitter_objc() *const TSLanguage;
extern fn tree_sitter_swift() *const TSLanguage;
extern fn tree_sitter_html() *const TSLanguage;
extern fn tree_sitter_css() *const TSLanguage;
extern fn tree_sitter_typescript() *const TSLanguage;
extern fn tree_sitter_tsx() *const TSLanguage;
extern fn tree_sitter_xml() *const TSLanguage;
extern fn tree_sitter_markdown() *const TSLanguage;
extern fn tree_sitter_ruby() *const TSLanguage;
extern fn tree_sitter_make() *const TSLanguage;
extern fn tree_sitter_ini() *const TSLanguage;

// ------------------------------------------------------------------ scopes

/// A capture mapped to a scope. `scope` is dotted atoms without the
/// language (it's appended, as syntect's scopes end with it); `>` nests a
/// span inside another; "" writes no span; "-" drops the capture, so a wider
/// one shows through. `kind`, `parent`, `grand` and `text` narrow a rule to
/// nodes of that kind, under a parent / grandparent of that kind, or with
/// one of those texts.
const Rule = struct {
    capture: []const u8,
    scope: []const u8,
    kind: []const u8 = "",
    parent: []const u8 = "",
    grand: []const u8 = "",
    text: []const []const u8 = &.{},
};

/// The common captures (tree-sitter's and nvim-treesitter's names) and the
/// scope syntect gives such tokens in most of bat's syntaxes. A capture
/// without an entry falls back to its parent name (`keyword.return` ->
/// `keyword`).
const scopes = [_]Rule{
    .{ .capture = "comment", .scope = "comment.line" },
    .{ .capture = "comment.documentation", .scope = "comment.block.documentation" },
    .{ .capture = "string", .scope = "string.quoted.double" },
    .{ .capture = "string.special.key", .scope = "string.quoted.double" },
    .{ .capture = "string.special.symbol", .scope = "constant.other.symbol" },
    .{ .capture = "string.special.url", .scope = "markup.underline.link" },
    .{ .capture = "string.special.path", .scope = "string.unquoted" },
    .{ .capture = "string.special", .scope = "string.other" },
    .{ .capture = "string.regexp", .scope = "string.regexp" },
    .{ .capture = "string.regex", .scope = "string.regexp" },
    .{ .capture = "string.escape", .scope = "constant.character.escape" },
    .{ .capture = "escape", .scope = "constant.character.escape" },
    .{ .capture = "character", .scope = "constant.character" },
    .{ .capture = "character.special", .scope = "constant.character" },
    .{ .capture = "number", .scope = "constant.numeric" },
    .{ .capture = "float", .scope = "constant.numeric" },
    .{ .capture = "boolean", .scope = "constant.language" },
    .{ .capture = "constant.builtin", .scope = "constant.language" },
    .{ .capture = "constant.macro", .scope = "constant.other" },
    .{ .capture = "constant", .scope = "constant.other" },
    .{ .capture = "keyword", .scope = "keyword.control" },
    .{ .capture = "keyword.operator", .scope = "keyword.operator" },
    .{ .capture = "keyword.function", .scope = "storage.type.function" },
    .{ .capture = "keyword.type", .scope = "storage.type" },
    .{ .capture = "keyword.modifier", .scope = "storage.modifier" },
    .{ .capture = "keyword.storage", .scope = "storage.modifier" },
    .{ .capture = "storageclass", .scope = "storage.modifier" },
    .{ .capture = "type.qualifier", .scope = "storage.modifier" },
    .{ .capture = "keyword.import", .scope = "keyword.control.import" },
    .{ .capture = "include", .scope = "keyword.control.import" },
    .{ .capture = "import", .scope = "keyword.control.import" },
    .{ .capture = "conditional", .scope = "keyword.control.conditional" },
    .{ .capture = "repeat", .scope = "keyword.control.loop" },
    .{ .capture = "exception", .scope = "keyword.control.exception" },
    .{ .capture = "keyword.directive", .scope = "keyword.control.directive" },
    .{ .capture = "preproc", .scope = "keyword.control.directive" },
    .{ .capture = "operator", .scope = "keyword.operator" },
    .{ .capture = "function", .scope = "entity.name.function" },
    .{ .capture = "function.call", .scope = "variable.function" },
    .{ .capture = "function.method.call", .scope = "variable.function" },
    .{ .capture = "function.builtin", .scope = "support.function" },
    .{ .capture = "function.method.builtin", .scope = "support.function" },
    .{ .capture = "function.macro", .scope = "support.macro" },
    .{ .capture = "function.special", .scope = "support.macro" },
    .{ .capture = "method", .scope = "entity.name.function" },
    .{ .capture = "method.call", .scope = "variable.function" },
    .{ .capture = "property.call", .scope = "variable.function" },
    .{ .capture = "constructor", .scope = "entity.name.type" },
    .{ .capture = "type", .scope = "entity.name.type" },
    .{ .capture = "type.builtin", .scope = "storage.type" },
    .{ .capture = "type.definition", .scope = "entity.name.type" },
    .{ .capture = "variable", .scope = "variable.other" },
    .{ .capture = "variable.parameter", .scope = "variable.parameter" },
    .{ .capture = "parameter", .scope = "variable.parameter" },
    .{ .capture = "variable.builtin", .scope = "variable.language" },
    .{ .capture = "parameter.builtin", .scope = "variable.language" },
    .{ .capture = "variable.member", .scope = "variable.other.member" },
    .{ .capture = "field", .scope = "variable.other.member" },
    .{ .capture = "property", .scope = "variable.other.property" },
    .{ .capture = "attribute", .scope = "entity.other.attribute-name" },
    .{ .capture = "tag", .scope = "entity.name.tag" },
    .{ .capture = "tag.attribute", .scope = "entity.other.attribute-name" },
    .{ .capture = "tag.delimiter", .scope = "punctuation.definition.tag" },
    .{ .capture = "tag.error", .scope = "invalid.illegal" },
    .{ .capture = "label", .scope = "entity.name.label" },
    .{ .capture = "module", .scope = "entity.name.namespace" },
    .{ .capture = "namespace", .scope = "entity.name.namespace" },
    .{ .capture = "punctuation", .scope = "" },
    .{ .capture = "punctuation.special", .scope = "punctuation.definition.variable" },
    .{ .capture = "delimiter", .scope = "" },
    .{ .capture = "embedded", .scope = "-" },
    .{ .capture = "diff.plus", .scope = "markup.inserted" },
    .{ .capture = "diff.minus", .scope = "markup.deleted" },
    .{ .capture = "diff.delta", .scope = "meta.diff.range" },
    .{ .capture = "markup.heading", .scope = "markup.heading" },
    .{ .capture = "text.title", .scope = "markup.heading" },
    .{ .capture = "markup.strong", .scope = "markup.bold" },
    .{ .capture = "text.strong", .scope = "markup.bold" },
    .{ .capture = "markup.italic", .scope = "markup.italic" },
    .{ .capture = "text.emphasis", .scope = "markup.italic" },
    .{ .capture = "markup.raw", .scope = "markup.raw.inline" },
    .{ .capture = "text.literal", .scope = "markup.raw.inline" },
    .{ .capture = "markup.link", .scope = "markup.underline.link" },
    .{ .capture = "markup.link.url", .scope = "markup.underline.link" },
    .{ .capture = "text.uri", .scope = "markup.underline.link" },
    .{ .capture = "text.reference", .scope = "constant.other.reference.link" },
    .{ .capture = "markup.list", .scope = "markup.list" },
    .{ .capture = "markup.quote", .scope = "markup.quote" },
    .{ .capture = "markup", .scope = "" },
    .{ .capture = "error", .scope = "invalid.illegal" },
    .{ .capture = "text.danger", .scope = "invalid.illegal" },
};

// --------------------------------------------------------------- grammars

const Grammar = struct {
    /// the wrapper span's scope, as syntect named the syntax (`source.shell.bash`)
    scope: []const u8,
    /// the atom syntect's scopes of this syntax end with
    suffix: []const u8,
    /// fenced code info strings that pick it
    tokens: []const []const u8,
    language: *const fn () callconv(.c) *const TSLanguage,
    highlights: []const u8,
    /// on the same node, the last pattern wins (nvim-style queries)
    last_wins: bool,
    /// tried before `scopes`
    rules: []const Rule = &.{},
};

/// Patterns added to a grammar's query, for tokens syntect colours that the
/// query leaves out (appended, so with last-wins precedence they win).
const rust_extra =
    \\["=" "?"] @operator
    \\((identifier) @constant (#match? @constant "^[A-Z][A-Z\\d_]+$"))
    \\
;
const toml_extra =
    \\(escape_sequence) @string.escape
    \\
;

const shell_rules = [_]Rule{
    .{ .capture = "function", .parent = "function_definition", .scope = "entity.name.function" },
    // bash builtins (bat's Bash syntax: support.function.<name>)
    .{ .capture = "function", .text = &.{ "printf", "echo", "cd", "source", "alias", "eval", "exec", "exit", "read", "set", "unset", "shift", "test", "trap", "type", "ulimit", "umask", "wait", "pushd", "popd", "dirs", "hash", "help", "history", "jobs", "kill", "let", "logout", "pwd", "return", "shopt", "times", "bg", "fg", "builtin", "caller", "command", "compgen", "complete", "disown", "enable", "getopts", "mapfile", "readarray", "suspend", "bind", "break", "continue" }, .scope = "support.function" },
    // every other @function is a command name
    .{ .capture = "function", .scope = "variable.function" },
    // words starting with `-`
    .{ .capture = "constant", .scope = "variable.parameter.option" },
    .{ .capture = "property", .scope = "variable.other.readwrite.assignment" },
    .{ .capture = "keyword", .text = &.{ "export", "local", "declare", "readonly", "typeset", "unset" }, .scope = "storage.modifier" },
    .{ .capture = "operator", .text = &.{"|"}, .scope = "keyword.operator.logical.pipe" },
    .{ .capture = "operator", .text = &.{"$"}, .scope = "punctuation.definition.variable" },
};

const rust_rules = [_]Rule{
    .{ .capture = "function.call", .text = &.{ "Ok", "Err", "Some" }, .scope = "support.type" },
    // `Type::new(..)` is a path, `x.new(..)` a method call
    .{ .capture = "function.call", .parent = "scoped_identifier", .scope = "" },
    .{ .capture = "function.call", .scope = "support.function" },
    .{ .capture = "constructor", .text = &.{"None"}, .scope = "support.type" },
    .{ .capture = "type", .text = &.{ "String", "Vec", "Option", "Result", "Box", "Rc", "Arc", "HashMap", "HashSet", "BTreeMap", "BTreeSet", "VecDeque", "Path", "PathBuf", "Cow", "Cell", "RefCell", "Mutex", "RwLock" }, .scope = "support.type" },
    .{ .capture = "keyword", .text = &.{ "await", "async" }, .scope = "" },
    .{ .capture = "function.method.call", .scope = "support.function" },
    .{ .capture = "property.call", .scope = "support.function" },
    .{ .capture = "property", .scope = "" },
    .{ .capture = "type.builtin", .scope = "storage.type" },
    .{ .capture = "constructor", .scope = "" },
    .{ .capture = "attribute", .scope = "variable.annotation" },
    .{ .capture = "keyword", .text = &.{ "fn", "struct", "enum", "impl", "trait", "type", "let", "const", "static", "mod" }, .scope = "storage.type" },
    .{ .capture = "keyword", .text = &.{ "pub", "mut", "ref", "unsafe", "extern", "move", "dyn" }, .scope = "storage.modifier" },
};

const json_rules = [_]Rule{};

const js_rules = [_]Rule{
    .{ .capture = "keyword", .text = &.{ "import", "export", "from", "as" }, .scope = "keyword.operator.module" },
    .{ .capture = "constructor", .scope = "variable.other.readwrite" },
    .{ .capture = "keyword", .text = &.{ "const", "let", "var", "function", "class" }, .scope = "storage.type" },
    .{ .capture = "keyword", .text = &.{ "new", "typeof", "instanceof", "delete", "void", "in", "of" }, .scope = "keyword.operator" },
    .{ .capture = "punctuation.delimiter", .text = &.{ ".", "?." }, .scope = "keyword.operator.accessor" },
    .{ .capture = "variable", .scope = "variable.other.readwrite" },
    .{ .capture = "variable.builtin", .scope = "variable.language" },
};

const python_rules = [_]Rule{
    .{ .capture = "variable", .scope = "" },
    .{ .capture = "property", .scope = "" },
    .{ .capture = "constructor", .scope = "" },
    .{ .capture = "type", .scope = "" },
};

const yaml_rules = [_]Rule{
    .{ .capture = "property", .scope = "entity.name.tag" },
    .{ .capture = "boolean", .scope = "constant.language.boolean" },
    .{ .capture = "punctuation.special", .scope = "entity.other.document.begin" },
    .{ .capture = "type", .scope = "storage.type.tag-handle" },
    .{ .capture = "label", .scope = "variable.other.anchor" },
};

const toml_rules = [_]Rule{
    // a bare key is @type everywhere, so tell table headers from keys
    .{ .capture = "type", .parent = "table", .scope = "entity.name.table" },
    .{ .capture = "type", .parent = "table_array_element", .scope = "entity.name.table" },
    .{ .capture = "type", .parent = "dotted_key", .grand = "table", .scope = "entity.name.table" },
    .{ .capture = "type", .parent = "dotted_key", .grand = "table_array_element", .scope = "entity.name.table" },
    .{ .capture = "type", .scope = "entity.name.tag" },
    // (the whole pair is @property)
    .{ .capture = "property", .scope = "" },
    .{ .capture = "operator", .scope = "punctuation.definition.key-value" },
    .{ .capture = "punctuation.bracket", .parent = "array", .scope = "punctuation.definition.array" },
    .{ .capture = "string.special", .scope = "constant.other.datetime" },
};

const diff_rules = [_]Rule{
    .{ .capture = "punctuation.special", .scope = "" },
    .{ .capture = "attribute", .scope = "meta.diff.range" },
    .{ .capture = "keyword", .scope = "meta.diff.header" },
    .{ .capture = "string.special.path", .scope = "meta.diff.header" },
    .{ .capture = "function", .scope = "" },
    .{ .capture = "variable.parameter", .scope = "" },
    .{ .capture = "constant", .scope = "" },
    .{ .capture = "comment", .scope = "" },
};

const c_rules = [_]Rule{
    .{ .capture = "type", .kind = "primitive_type", .scope = "storage.type" },
    .{ .capture = "type", .kind = "sized_type_specifier", .scope = "storage.type" },
    .{ .capture = "property", .scope = "variable.other.member" },
    .{ .capture = "variable", .scope = "" },
    .{ .capture = "keyword", .text = &.{ "#include", "#define", "#if", "#ifdef", "#ifndef", "#else", "#elif", "#endif" }, .scope = "keyword.control.import" },
};

const html_rules = [_]Rule{
    .{ .capture = "punctuation.bracket", .scope = "punctuation.definition.tag" },
    .{ .capture = "constant", .scope = "constant.character.entity" },
};

const xml_rules = [_]Rule{
    .{ .capture = "tag", .scope = "entity.name.tag.localname" },
    .{ .capture = "punctuation.bracket", .scope = "punctuation.definition.tag" },
    .{ .capture = "punctuation.delimiter", .scope = "punctuation.definition.tag" },
    .{ .capture = "property", .scope = "entity.other.attribute-name.localname" },
    .{ .capture = "attribute", .scope = "entity.other.attribute-name.localname" },
    .{ .capture = "keyword", .scope = "entity.name.tag" },
    .{ .capture = "markup", .scope = "" },
    .{ .capture = "markup.heading", .scope = "" },
    .{ .capture = "markup.raw", .scope = "string.unquoted.cdata" },
};

const css_rules = [_]Rule{
    .{ .capture = "property", .scope = "support.type.property-name" },
    .{ .capture = "type", .scope = "entity.other.attribute-name.class" },
    .{ .capture = "attribute", .scope = "entity.other.attribute-name" },
    .{ .capture = "function", .scope = "support.function" },
    .{ .capture = "keyword", .scope = "keyword.control.at-rule" },
    .{ .capture = "variable", .scope = "variable.other.custom-property" },
    .{ .capture = "string.special", .scope = "constant.other.color" },
};

const ts_rules = [_]Rule{
    .{ .capture = "keyword", .text = &.{ "import", "export", "from", "as" }, .scope = "keyword.control.import" },
    .{ .capture = "type", .scope = "entity.name.type" },
    .{ .capture = "type.builtin", .scope = "support.type.primitive" },
} ++ js_rules;

const markdown_rules = [_]Rule{
    .{ .capture = "text.title", .scope = "markup.heading>entity.name.section" },
    .{ .capture = "punctuation.special", .parent = "atx_heading", .scope = "markup.heading>punctuation.definition.heading" },
    .{ .capture = "punctuation.special", .parent = "setext_heading", .scope = "markup.heading>punctuation.definition.heading" },
    .{ .capture = "punctuation.special", .parent = "list_item", .scope = "markup.list>punctuation.definition.list_item" },
    .{ .capture = "punctuation.special", .scope = "punctuation.definition" },
    .{ .capture = "punctuation.delimiter", .scope = "punctuation.definition.raw.code-fence" },
    .{ .capture = "text.literal", .scope = "markup.raw.block" },
    .{ .capture = "none", .scope = "" },
};

const ruby_rules = [_]Rule{
    .{ .capture = "string.special.symbol", .scope = "constant.other.symbol" },
    .{ .capture = "variable", .scope = "" },
    .{ .capture = "constructor", .scope = "support.class" },
    .{ .capture = "function.method", .scope = "entity.name.function" },
};

const swift_rules = [_]Rule{
    .{ .capture = "variable", .scope = "" },
    .{ .capture = "variable.member", .scope = "" },
    .{ .capture = "type", .scope = "support.type" },
};

const grammars = [_]Grammar{
    .{ .scope = "source.shell.bash", .suffix = "shell", .tokens = &.{ "sh", "bash", "shell", "zsh", "console", "shell-session", "ksh" }, .language = tree_sitter_bash, .highlights = @embedFile("ts_bash_highlights"), .last_wins = true, .rules = &shell_rules },
    .{ .scope = "source.json", .suffix = "json", .tokens = &.{ "json", "jsonc", "json5", "geojson" }, .language = tree_sitter_json, .highlights = @embedFile("ts_json_highlights"), .last_wins = true, .rules = &json_rules },
    .{ .scope = "source.rust", .suffix = "rust", .tokens = &.{ "rust", "rs" }, .language = tree_sitter_rust, .highlights = @embedFile("ts_rust_highlights") ++ "\n" ++ rust_extra, .last_wins = true, .rules = &rust_rules },
    .{ .scope = "source.python", .suffix = "python", .tokens = &.{ "python", "py", "python3" }, .language = tree_sitter_python, .highlights = @embedFile("ts_python_highlights"), .last_wins = true, .rules = &python_rules },
    .{ .scope = "source.js", .suffix = "js", .tokens = &.{ "javascript", "js", "mjs", "cjs", "jsx" }, .language = tree_sitter_javascript, .highlights = @embedFile("ts_javascript_highlights"), .last_wins = true, .rules = &js_rules },
    .{ .scope = "source.yaml", .suffix = "yaml", .tokens = &.{ "yaml", "yml" }, .language = tree_sitter_yaml, .highlights = @embedFile("ts_yaml_highlights"), .last_wins = true, .rules = &yaml_rules },
    .{ .scope = "source.toml", .suffix = "toml", .tokens = &.{"toml"}, .language = tree_sitter_toml, .highlights = @embedFile("ts_toml_highlights") ++ "\n" ++ toml_extra, .last_wins = true, .rules = &toml_rules },
    .{ .scope = "source.zig", .suffix = "zig", .tokens = &.{ "zig", "zon" }, .language = tree_sitter_zig, .highlights = @embedFile("ts_zig_highlights"), .last_wins = true },
    .{ .scope = "source.lua", .suffix = "lua", .tokens = &.{"lua"}, .language = tree_sitter_lua, .highlights = @embedFile("ts_lua_highlights"), .last_wins = true },
    .{ .scope = "source.diff", .suffix = "diff", .tokens = &.{ "diff", "patch" }, .language = tree_sitter_diff, .highlights = @embedFile("ts_diff_highlights"), .last_wins = true, .rules = &diff_rules },
    .{ .scope = "source.c", .suffix = "c", .tokens = &.{ "c", "h" }, .language = tree_sitter_c, .highlights = @embedFile("ts_c_highlights"), .last_wins = true, .rules = &c_rules },
    // tree-sitter-objc's query inherits C's
    .{ .scope = "source.objc", .suffix = "objc", .tokens = &.{ "objc", "objective-c", "objectivec", "obj-c", "m" }, .language = tree_sitter_objc, .highlights = @embedFile("ts_objc_highlights") ++ "\n" ++ @embedFile("ts_c_highlights"), .last_wins = true, .rules = &c_rules },
    .{ .scope = "source.swift", .suffix = "swift", .tokens = &.{"swift"}, .language = tree_sitter_swift, .highlights = @embedFile("ts_swift_highlights"), .last_wins = true, .rules = &swift_rules },
    .{ .scope = "text.html.basic", .suffix = "html", .tokens = &.{ "html", "htm", "xhtml" }, .language = tree_sitter_html, .highlights = @embedFile("ts_html_highlights"), .last_wins = true, .rules = &html_rules },
    .{ .scope = "source.css", .suffix = "css", .tokens = &.{"css"}, .language = tree_sitter_css, .highlights = @embedFile("ts_css_highlights"), .last_wins = true, .rules = &css_rules },
    // tree-sitter-typescript's queries add to JavaScript's (its tree-sitter.json)
    .{ .scope = "source.ts", .suffix = "ts", .tokens = &.{ "ts", "typescript", "mts", "cts" }, .language = tree_sitter_typescript, .highlights = @embedFile("ts_typescript_highlights") ++ "\n" ++ @embedFile("ts_javascript_highlights"), .last_wins = true, .rules = &ts_rules },
    .{ .scope = "source.tsx", .suffix = "tsx", .tokens = &.{"tsx"}, .language = tree_sitter_tsx, .highlights = @embedFile("ts_tsx_highlights") ++ "\n" ++ @embedFile("ts_javascript_highlights"), .last_wins = true, .rules = &ts_rules },
    .{ .scope = "text.xml", .suffix = "xml", .tokens = &.{ "xml", "plist", "svg", "xsd", "xsl", "rss" }, .language = tree_sitter_xml, .highlights = @embedFile("ts_xml_highlights"), .last_wins = true, .rules = &xml_rules },
    .{ .scope = "text.html.markdown", .suffix = "markdown", .tokens = &.{ "markdown", "md", "mdx" }, .language = tree_sitter_markdown, .highlights = @embedFile("ts_markdown_highlights"), .last_wins = true, .rules = &markdown_rules },
    .{ .scope = "source.ruby", .suffix = "ruby", .tokens = &.{ "ruby", "rb", "gemspec", "rake" }, .language = tree_sitter_ruby, .highlights = @embedFile("ts_ruby_highlights"), .last_wins = true, .rules = &ruby_rules },
    .{ .scope = "source.makefile", .suffix = "makefile", .tokens = &.{ "make", "makefile", "mk", "mak" }, .language = tree_sitter_make, .highlights = @embedFile("ts_make_highlights"), .last_wins = true },
    .{ .scope = "source.ini", .suffix = "ini", .tokens = &.{ "ini", "dosini", "cfg", "gitconfig", "editorconfig", "desktop" }, .language = tree_sitter_ini, .highlights = @embedFile("ts_ini_highlights"), .last_wins = true },
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
        std.debug.print("wiki: {s} highlights.scm: query error {d} at byte {d}\n", .{ g.suffix, kind, offset });
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
    /// index into the render's scope list; 0 = no span
    scope: u32,
    len: u32,
    pattern: u32,
};

const none = std.math.maxInt(u32);

/// The scopes one render uses, deduplicated; owners point into it.
const ScopeList = struct {
    items: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    fn id(self: *ScopeList, arena: Allocator, scope: []const u8) !u32 {
        if (scope.len == 0) return 0;
        const gop = try self.index.getOrPut(arena, scope);
        if (!gop.found_existing) {
            if (self.items.items.len == 0) try self.items.append(arena, "");
            gop.value_ptr.* = @intCast(self.items.items.len);
            try self.items.append(arena, scope);
        }
        return gop.value_ptr.*;
    }
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

    const owners = try arena.alloc(Owner, code.len);
    @memset(owners, .{ .scope = none, .len = none, .pattern = 0 });
    var list: ScopeList = .{};
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
            const scope = try resolve(arena, g, name, cap.node, code[start..end]);
            if (std.mem.eql(u8, scope, "-")) continue;
            const len = end - start;
            const id = try list.id(arena, scope);
            claim(owners[start..end], g.last_wins, .{ .scope = id, .len = len, .pattern = m.pattern_index });
            // syntect's punctuation scope on a string's quotes
            if (std.mem.startsWith(u8, scope, "string") and std.mem.indexOfScalar(u8, scope, '>') == null) {
                const n = quotes(code[start..end]);
                if (n > 0) {
                    const begin = try list.id(arena, try std.mem.concat(arena, u8, &.{ scope, ">punctuation.definition.string.begin" }));
                    const finish = try list.id(arena, try std.mem.concat(arena, u8, &.{ scope, ">punctuation.definition.string.end" }));
                    claim(owners[start .. start + n], g.last_wins, .{ .scope = begin, .len = 1, .pattern = m.pattern_index });
                    claim(owners[end - n .. end], g.last_wins, .{ .scope = finish, .len = 1, .pattern = m.pattern_index });
                }
            }
        }
    }

    try out.appendSlice(arena, "<span class=\"");
    try classes(arena, out, g.scope, "");
    try out.appendSlice(arena, "\">");
    var i: usize = 0;
    while (i < code.len) {
        const scope = owners[i].scope;
        var j = i + 1;
        while (j < code.len and owners[j].scope == scope) j += 1;
        if (scope == none or scope == 0) {
            try escape(arena, out, code[i..j]);
        } else {
            var depth: usize = 0;
            var parts = std.mem.splitScalar(u8, list.items.items[scope], '>');
            while (parts.next()) |part| {
                try out.appendSlice(arena, "<span class=\"");
                try classes(arena, out, part, g.suffix);
                try out.appendSlice(arena, "\">");
                depth += 1;
            }
            try escape(arena, out, code[i..j]);
            for (0..depth) |_| try out.appendSlice(arena, "</span>");
        }
        i = j;
    }
    try out.appendSlice(arena, "</span>");
    return true;
}

fn claim(owners: []Owner, last_wins: bool, new: Owner) void {
    for (owners) |*o| {
        const better = new.len < o.len or (new.len == o.len and (if (last_wins) new.pattern >= o.pattern else new.pattern < o.pattern or o.scope == none));
        if (better) o.* = new;
    }
}

/// How many quote chars open (and close) a string token, or 0.
fn quotes(text: []const u8) usize {
    if (text.len < 2) return 0;
    const q = text[0];
    if (q != '"' and q != '\'' and q != '`') return 0;
    var n: usize = 1;
    while (n < 3 and n < text.len and text[n] == q) n += 1;
    // `""` is two one-char quotes, not an opening run
    if (n * 2 > text.len) n = 1;
    if (n == 2) n = 1;
    for (text[text.len - n ..]) |ch| if (ch != q) return 0;
    return n;
}

/// The scope a capture on `node` gets, "" for no span.
fn resolve(arena: Allocator, g: Grammar, name: []const u8, node: TSNode, text: []const u8) ![]const u8 {
    const kind = std.mem.span(ts_node_type(node));
    const parent = ts_node_parent(node);
    const parent_kind: []const u8 = if (parent.id != null) std.mem.span(ts_node_type(parent)) else "";
    const grand = if (parent.id != null) ts_node_parent(parent) else parent;
    const grand_kind: []const u8 = if (grand.id != null) std.mem.span(ts_node_type(grand)) else "";
    const ctx: Context = .{ .kind = kind, .parent = parent_kind, .grand = grand_kind, .text = text };

    const callable = std.mem.startsWith(u8, name, "function") or std.mem.startsWith(u8, name, "method") or std.mem.startsWith(u8, name, "property");
    if (callable and std.mem.indexOf(u8, name, "call") == null and (isCall(parent_kind) or isCall(grand_kind))) {
        const called = try std.mem.concat(arena, u8, &.{ name, ".call" });
        if (exact(g.rules, called, ctx)) |s| return s;
        if (exact(&scopes, called, ctx)) |s| return s;
        // `function.method.call` -> `function.call`
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const base = try std.mem.concat(arena, u8, &.{ name[0..dot], ".call" });
            if (exact(g.rules, base, ctx)) |s| return s;
            if (exact(&scopes, base, ctx)) |s| return s;
        }
    }
    var n = name;
    while (true) {
        if (exact(g.rules, n, ctx)) |s| return s;
        if (exact(&scopes, n, ctx)) |s| return s;
        n = n[0 .. std.mem.lastIndexOfScalar(u8, n, '.') orelse return ""];
    }
}

const Context = struct { kind: []const u8, parent: []const u8, grand: []const u8, text: []const u8 };

fn exact(rules: []const Rule, name: []const u8, ctx: Context) ?[]const u8 {
    for (rules) |r| {
        if (!std.mem.eql(u8, r.capture, name)) continue;
        if (r.kind.len > 0 and !std.mem.eql(u8, r.kind, ctx.kind)) continue;
        if (r.parent.len > 0 and !std.mem.eql(u8, r.parent, ctx.parent)) continue;
        if (r.grand.len > 0 and !std.mem.eql(u8, r.grand, ctx.grand)) continue;
        if (r.text.len > 0) {
            const found = for (r.text) |t| {
                if (std.mem.eql(u8, t, ctx.text)) break true;
            } else false;
            if (!found) continue;
        }
        return r.scope;
    }
    return null;
}

fn isCall(kind: []const u8) bool {
    return std.mem.indexOf(u8, kind, "call") != null or std.mem.indexOf(u8, kind, "invocation") != null;
}

/// `entity.name.function` + `rust` -> `hl-entity hl-name hl-function hl-rust`
fn classes(arena: Allocator, out: *Out, scope: []const u8, suffix: []const u8) !void {
    var first = true;
    var atoms = std.mem.tokenizeScalar(u8, scope, '.');
    while (atoms.next()) |atom| {
        if (!first) try out.append(arena, ' ');
        first = false;
        try out.appendSlice(arena, prefix);
        try out.appendSlice(arena, atom);
    }
    if (suffix.len > 0) {
        try out.appendSlice(arena, " " ++ prefix);
        try out.appendSlice(arena, suffix);
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

/// CSS for the highlight classes, appended to the bundled style.css: what
/// the Rust wiki appended, syntect's `css_for_theme_with_class_style` for
/// InspiredGitHub (light) and base16-ocean.dark with the `hl-` prefix.
pub const css = @embedFile("highlight.css");

test "highlight" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: Out = .empty;
    try write(a, &out, "rust", "fn main() { let x = \"hi\"; foo(); } // c\n");
    try std.testing.expect(std.mem.startsWith(u8, out.items, "<span class=\"hl-source hl-rust\">"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<span class=\"hl-storage hl-type hl-rust\">fn</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<span class=\"hl-entity hl-name hl-function hl-rust\">main</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<span class=\"hl-support hl-function hl-rust\">foo</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<span class=\"hl-string hl-quoted hl-double hl-rust\"><span class=\"hl-punctuation hl-definition hl-string hl-begin hl-rust\">&quot;</span></span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hl-comment") != null);
    out = .empty;
    try write(a, &out, "", "a < b\n");
    try std.testing.expectEqualStrings("<span class=\"hl-text hl-plain\">a &lt; b\n</span>", out.items);
    out = .empty;
    try write(a, &out, "sh", "ls 'x' # y\n");
    try std.testing.expect(std.mem.startsWith(u8, out.items, "<span class=\"hl-source hl-shell hl-bash\"><span class=\"hl-variable hl-function hl-shell\">ls</span>"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<span class=\"hl-comment hl-line hl-shell\">") != null);
    // every grammar's query compiles
    for (grammars, 0..) |g, i| {
        if (query(i) == null) {
            std.debug.print("{s}: query does not compile\n", .{g.suffix});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), quotes("\"\"\"doc\"\"\""));
    try std.testing.expectEqual(@as(usize, 1), quotes("\"\""));
    try std.testing.expectEqual(@as(usize, 0), quotes("r\"x\""));
}
