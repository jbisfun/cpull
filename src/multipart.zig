// multipart/form-data bodies (RFC 7578), for forms that upload a file
// without javascript (the themed thread page's attachment form). std has no
// parser for them; this reads the one shape browsers send: parts separated by
// "--boundary" lines, each with its headers, a blank line and its bytes.
const std = @import("std");

pub const Part = struct {
    // the form field's name
    name: []const u8,
    // the file's name, null for a plain field
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

// the boundary a content-type header names, or null when it isn't multipart/form-data
pub fn boundary(content_type: []const u8) ?[]const u8 {
    var params = std.mem.splitScalar(u8, content_type, ';');
    const kind = std.mem.trim(u8, params.first(), " \t");
    if (!std.ascii.eqlIgnoreCase(kind, "multipart/form-data")) return null;
    while (params.next()) |param| {
        const p = std.mem.trim(u8, param, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, p[0..eq], " \t"), "boundary")) continue;
        const value = std.mem.trim(u8, p[eq + 1 ..], " \t");
        const unquoted = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
        if (unquoted.len == 0 or unquoted.len > 70) return null;
        return unquoted;
    }
    return null;
}

pub const Iterator = struct {
    body: []const u8,
    delimiter: []const u8,
    pos: usize,
    done: bool = false,

    // the next part, null after the closing delimiter; error.Malformed on a
    // body that doesn't follow the format
    pub fn next(self: *Iterator) !?Part {
        if (self.done) return null;
        // after a delimiter: "--" closes the body, else the line ends
        if (std.mem.startsWith(u8, self.body[self.pos..], "--")) {
            self.done = true;
            return null;
        }
        const line_end = std.mem.indexOfPos(u8, self.body, self.pos, "\r\n") orelse return error.Malformed;
        var at = line_end + 2;
        var part: Part = .{ .name = "", .filename = null, .content_type = null, .data = "" };
        var has_name = false;
        // the part's headers, up to a blank line
        while (true) {
            const end = std.mem.indexOfPos(u8, self.body, at, "\r\n") orelse return error.Malformed;
            const header = self.body[at..end];
            at = end + 2;
            if (header.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.Malformed;
            const key = std.mem.trim(u8, header[0..colon], " \t");
            const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
                part.name = dispositionParam(value, "name") orelse return error.Malformed;
                part.filename = dispositionParam(value, "filename");
                has_name = true;
            } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
                part.content_type = value;
            }
        }
        if (!has_name) return error.Malformed;
        // the data runs to the next "\r\n--boundary"
        const close = std.mem.indexOfPos(u8, self.body, at, self.delimiter) orelse return error.Malformed;
        part.data = self.body[at..close];
        self.pos = close + self.delimiter.len;
        return part;
    }
};

// iterate `body`'s parts; `delimiter_buf` holds "\r\n--" ++ boundary
pub fn iterate(body: []const u8, boundary_value: []const u8, delimiter_buf: []u8) !Iterator {
    const delimiter = try std.fmt.bufPrint(delimiter_buf, "\r\n--{s}", .{boundary_value});
    // the body opens with the delimiter, without its leading line break
    const first = delimiter[2..];
    const start = std.mem.indexOf(u8, body, first) orelse return error.Malformed;
    return .{ .body = body, .delimiter = delimiter, .pos = start + first.len };
}

// a content-disposition parameter's value, quoted or not. browsers escape a
// filename's quote and line breaks as %22, %0D and %0A, which are left as is.
fn dispositionParam(value: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < value.len) {
        const semi = std.mem.indexOfScalarPos(u8, value, i, ';') orelse return null;
        var at = semi + 1;
        while (at < value.len and (value[at] == ' ' or value[at] == '\t')) at += 1;
        const eq = std.mem.indexOfScalarPos(u8, value, at, '=') orelse return null;
        const name = std.mem.trim(u8, value[at..eq], " \t");
        var rest = eq + 1;
        var result: []const u8 = undefined;
        if (rest < value.len and value[rest] == '"') {
            const close = std.mem.indexOfScalarPos(u8, value, rest + 1, '"') orelse return null;
            result = value[rest + 1 .. close];
            rest = close + 1;
        } else {
            const end = std.mem.indexOfScalarPos(u8, value, rest, ';') orelse value.len;
            result = std.mem.trim(u8, value[rest..end], " \t");
            rest = end;
        }
        if (std.ascii.eqlIgnoreCase(name, key)) return result;
        i = rest;
    }
    return null;
}

test "a browser's file upload" {
    const body = "--XyZ\r\n" ++
        "Content-Disposition: form-data; name=\"note\"\r\n\r\n" ++
        "hi\r\n" ++
        "--XyZ\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a b.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "line1\r\nline2\r\n" ++
        "--XyZ--\r\n";
    const b = boundary("multipart/form-data; boundary=XyZ").?;
    try std.testing.expectEqualStrings("XyZ", b);
    var buf: [80]u8 = undefined;
    var it = try iterate(body, b, &buf);
    const note = (try it.next()).?;
    try std.testing.expectEqualStrings("note", note.name);
    try std.testing.expectEqual(@as(?[]const u8, null), note.filename);
    try std.testing.expectEqualStrings("hi", note.data);
    const file = (try it.next()).?;
    try std.testing.expectEqualStrings("file", file.name);
    try std.testing.expectEqualStrings("a b.txt", file.filename.?);
    try std.testing.expectEqualStrings("text/plain", file.content_type.?);
    try std.testing.expectEqualStrings("line1\r\nline2", file.data);
    try std.testing.expectEqual(@as(?Part, null), try it.next());
    try std.testing.expectEqual(@as(?[]const u8, null), boundary("application/x-www-form-urlencoded"));
    try std.testing.expectEqualStrings("ab", boundary("multipart/form-data; boundary=\"ab\"").?);
}
