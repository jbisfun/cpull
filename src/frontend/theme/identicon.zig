//! Identicons: a GitHub-style avatar (a 5x5 grid mirrored around its middle
//! column, one hue) drawn from a hash, as SVG. cpull gives every repo one,
//! from the SHA-1 of its name (see `forName`).
//!
//! A faithful port of identicon.js 2.3.3 by Stewart Lord
//! (https://github.com/stewartlord/identicon.js, BSD-2-Clause, copyright
//! notice below): the same options and defaults, the same cell geometry,
//! pixel bits, hue and colour maths, and `Identicon.writeSvg` writes exactly
//! the SVG identicon.js's `toString(true)` returns for format "svg" (the
//! tests compare against its output). `Identicon.writeTile` is cpull's own
//! variant of that SVG for the themed UI: scalable, with a rounded
//! background tile whose colour follows the light/dark theme.
//!
//! Depends only on std, like the rest of the theme layer.
//!
//! identicon.js: Copyright (c) 2018, Stewart Lord. All rights reserved.
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are
//! met: Redistributions of source code must retain the above copyright notice,
//! this list of conditions and the following disclaimer. Redistributions in
//! binary form must reproduce the above copyright notice, this list of
//! conditions and the following disclaimer in the documentation and/or other
//! materials provided with the distribution. THIS SOFTWARE IS PROVIDED BY THE
//! COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
//! WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
//! MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
//! EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
//! INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//! (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//! LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//! ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//! (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
//! THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
const std = @import("std");

// identicon.js's options. As there, a zero size, saturation or brightness
// means the default (it reads them with `||`).
pub const Options = struct {
    // r, g, b, a (0-255)
    background: [4]u8 = .{ 240, 240, 240, 255 },
    // of the size, on each side
    margin: f64 = 0.08,
    size: u32 = 64,
    saturation: f64 = 0.7,
    brightness: f64 = 0.5,
    // r, g, b, a; null derives it from the hash
    foreground: ?[4]u8 = null,
};

// a colour as identicon.js holds it: channels as unrounded numbers, alpha as
// given (an out-of-range or missing alpha writes as opaque)
const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: ?u8 = null,

    fn fromBytes(c: [4]u8) Color {
        return .{ .r = @floatFromInt(c[0]), .g = @floatFromInt(c[1]), .b = @floatFromInt(c[2]), .a = c[3] };
    }

    // Svg.prototype.color: "rgba(r,g,b,a)", channels rounded, alpha / 255
    fn format(self: Color, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const alpha: f64 = if (self.a) |a| @as(f64, @floatFromInt(a)) / 255 else 1;
        try w.print("rgba({d},{d},{d},{d})", .{ jsRound(self.r), jsRound(self.g), jsRound(self.b), alpha });
    }

    fn eql(a: Color, b: Color) bool {
        const alpha_a: f64 = if (a.a) |x| @floatFromInt(x) else 255;
        const alpha_b: f64 = if (b.a) |x| @floatFromInt(x) else 255;
        return jsRound(a.r) == jsRound(b.r) and jsRound(a.g) == jsRound(b.g) and jsRound(a.b) == jsRound(b.b) and alpha_a == alpha_b;
    }
};

// Math.round for the non-negative channel values
fn jsRound(x: f64) i64 {
    return @intFromFloat(@floor(x + 0.5));
}

// a cell of the image: its square in pixels
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Identicon = struct {
    hash: []const u8,
    size: u32,
    margin: f64,
    background: Color,
    foreground: Color,

    // identicon.js's constructor: `hash` is a hex string of at least 15
    // characters (the first 15 pick the cells, the last 7 the hue)
    pub fn init(hash: []const u8, options: Options) error{InvalidHash}!Identicon {
        if (hash.len < 15) return error.InvalidHash;
        // parseInt(hash.substr(-7), 16): the leading hex digits of the last 7
        const tail = hash[hash.len - 7 ..];
        var digits: usize = 0;
        while (digits < tail.len and std.ascii.isHex(tail[digits])) digits += 1;
        // parseInt yields NaN here and identicon.js writes NaN channels; refuse instead
        if (digits == 0) return error.InvalidHash;
        const value = std.fmt.parseInt(u32, tail[0..digits], 16) catch unreachable;
        const hue = @as(f64, @floatFromInt(value)) / 0xfffffff;
        const saturation = if (options.saturation != 0) options.saturation else 0.7;
        const brightness = if (options.brightness != 0) options.brightness else 0.5;
        return .{
            .hash = hash,
            .size = if (options.size != 0) options.size else 64,
            .margin = options.margin,
            .background = .fromBytes(options.background),
            .foreground = if (options.foreground) |fg| .fromBytes(fg) else hsl2rgb(hue, saturation, brightness),
        };
    }

    // whether cell `i` of the 15 (down the middle column, then mirrored
    // outwards) is painted: an even hex digit paints, an odd one doesn't
    // (parseInt(c, 16) % 2 ? bg : fg, so a non-hex NaN paints too)
    pub fn painted(self: Identicon, i: usize) bool {
        const digit = std.fmt.charToDigit(self.hash[i], 16) catch return true;
        return digit % 2 == 0;
    }

    // the 5x5 grid, row-major, true where painted
    pub fn grid(self: Identicon) [25]bool {
        var cells: [25]bool = undefined;
        for (0..15) |i| {
            const row = i % 5;
            const col: usize = 2 - i / 5;
            cells[row * 5 + col] = self.painted(i);
            cells[row * 5 + 4 - col] = self.painted(i);
        }
        return cells;
    }

    // the painted cells' squares, in identicon.js's drawing order. a cell
    // whose colour comes out the background's is left out, as getDump does.
    pub fn rects(self: Identicon, out: *[25]Rect) []Rect {
        const size = self.size;
        const base_margin: u32 = @intFromFloat(@floor(@as(f64, @floatFromInt(size)) * self.margin));
        const cell = (size -| base_margin * 2) / 5;
        const margin = (size - cell * 5) / 2;
        const same = self.foreground.eql(self.background);
        var n: usize = 0;
        for (0..15) |i| {
            if (same or !self.painted(i)) continue;
            const row: u32 = @intCast(i % 5);
            const cols: []const u32 = switch (i / 5) {
                0 => &.{2},
                1 => &.{ 1, 3 },
                else => &.{ 0, 4 },
            };
            for (cols) |col| {
                out[n] = .{ .x = col * cell + margin, .y = row * cell + margin, .w = cell, .h = cell };
                n += 1;
            }
        }
        return out[0..n];
    }

    // identicon.js's SVG (new Identicon(hash, {format: "svg", ...}).toString(true))
    pub fn writeSvg(self: Identicon, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("<svg xmlns='http://www.w3.org/2000/svg' width='{d}' height='{d}' style='background-color:", .{ self.size, self.size });
        try self.background.format(w);
        try w.writeAll(";'>");
        try self.writeCells(w);
        try w.writeAll("</svg>");
    }

    // cpull's variant for the themed UI: a viewBox so CSS sizes it, a
    // rounded background tile filled by `.cpull-identicon-bg` (the theme's
    // style.css colours it per light/dark), and the cells as identicon.js
    // draws them. `standalone` embeds that colouring as a prefers-color-scheme
    // style, for the SVG served as a file; inline copies take the page's CSS.
    pub fn writeTile(self: Identicon, w: *std.Io.Writer, tile: Tile) std.Io.Writer.Error!void {
        try w.print("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 {d} {d}' width='{d}' height='{d}' class='cpull-identicon", .{ self.size, self.size, self.size, self.size });
        if (tile.class.len > 0) try w.print(" {s}", .{tile.class});
        try w.writeAll("' aria-hidden='true' focusable='false'>");
        if (tile.standalone) try w.writeAll(standalone_style);
        try w.print("<rect class='cpull-identicon-bg' width='{d}' height='{d}' rx='{d}'/>", .{ self.size, self.size, self.size / 8 });
        try self.writeCells(w);
        try w.writeAll("</svg>");
    }

    fn writeCells(self: Identicon, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const stroke = @as(f64, @floatFromInt(self.size)) * 0.005;
        try w.writeAll("<g style='fill:");
        try self.foreground.format(w);
        try w.writeAll("; stroke:");
        try self.foreground.format(w);
        try w.print("; stroke-width:{d};'>", .{stroke});
        var buf: [25]Rect = undefined;
        for (self.rects(&buf)) |r| try w.print("<rect  x='{d}' y='{d}' width='{d}' height='{d}'/>", .{ r.x, r.y, r.w, r.h });
        try w.writeAll("</g>");
    }
};

pub const Tile = struct {
    // more classes after "cpull-identicon" (sizes: see style.css)
    class: []const u8 = "",
    standalone: bool = false,
};

// the tile colours of style.css's --cpull-identicon-bg, for a served file
pub const standalone_style = "<style>.cpull-identicon-bg{fill:#f0f0f0}@media (prefers-color-scheme:dark){.cpull-identicon-bg{fill:#26272a}}</style>";

// identicon.js's hsl2rgb, adapted there from https://gist.github.com/aemkei/1325937:
// hue 0-1, saturation and brightness 0-1, channels 0-255 unrounded
fn hsl2rgb(hue: f64, saturation: f64, brightness: f64) Color {
    const h = hue * 6;
    var s = saturation;
    var b = brightness;
    s *= if (b < 0.5) b else 1 - b;
    b += s;
    const frac = @mod(h, 1);
    var v: [6]f64 = undefined;
    v[0] = b;
    v[1] = b - frac * s * 2;
    s *= 2;
    b -= s;
    v[2] = b;
    v[3] = b;
    v[4] = b + frac * s;
    v[5] = b + s;
    // ~~h, h|16, h|8 are int32 operations on the truncated hue
    const hi: u32 = @intFromFloat(@trunc(h));
    return .{ .r = v[hi % 6] * 255, .g = v[(hi | 16) % 6] * 255, .b = v[(hi | 8) % 6] * 255 };
}

// the hash cpull draws a name's identicon from: SHA-1 of the name, lowercase hex
pub fn hashName(name: []const u8) [40]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(name, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// `name`'s identicon tile as SVG markup, owned by the caller
pub fn tileFor(allocator: std.mem.Allocator, name: []const u8, tile: Tile) ![]u8 {
    const hash = hashName(name);
    const icon = Identicon.init(&hash, .{}) catch unreachable;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try icon.writeTile(&out.writer, tile);
    return out.toOwnedSlice();
}

fn expectSvg(expected: []const u8, hash: []const u8, options: Options) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try (try Identicon.init(hash, options)).writeSvg(&out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

// expected outputs from identicon.js 2.3.3 under node:
// new Identicon(sha1hex(name), {format: "svg", ...}).toString(true)
test "writeSvg matches identicon.js byte for byte" {
    const haxy = hashName("haxy");
    try std.testing.expectEqualStrings("8a51e166ecadb306679b22ce20dc0a8785dae675", &haxy);
    try expectSvg("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' style='background-color:rgba(240,240,240,1);'><g style='fill:rgba(38,217,73,1); stroke:rgba(38,217,73,1); stroke-width:0.32;'><rect  x='27' y='7' width='10' height='10'/><rect  x='27' y='17' width='10' height='10'/><rect  x='27' y='47' width='10' height='10'/><rect  x='17' y='17' width='10' height='10'/><rect  x='37' y='17' width='10' height='10'/><rect  x='17' y='27' width='10' height='10'/><rect  x='37' y='27' width='10' height='10'/><rect  x='17' y='37' width='10' height='10'/><rect  x='37' y='37' width='10' height='10'/><rect  x='17' y='47' width='10' height='10'/><rect  x='37' y='47' width='10' height='10'/><rect  x='7' y='7' width='10' height='10'/><rect  x='47' y='7' width='10' height='10'/><rect  x='7' y='47' width='10' height='10'/><rect  x='47' y='47' width='10' height='10'/></g></svg>", &haxy, .{});
    // {size: 420, margin: 0.2, background: [20, 30, 40, 128], saturation: 0.4, brightness: 0.3}
    try expectSvg("<svg xmlns='http://www.w3.org/2000/svg' width='420' height='420' style='background-color:rgba(20,30,40,0.5019607843137255);'><g style='fill:rgba(46,107,58,1); stroke:rgba(46,107,58,1); stroke-width:2.1;'><rect  x='185' y='85' width='50' height='50'/><rect  x='185' y='135' width='50' height='50'/><rect  x='185' y='285' width='50' height='50'/><rect  x='135' y='135' width='50' height='50'/><rect  x='235' y='135' width='50' height='50'/><rect  x='135' y='185' width='50' height='50'/><rect  x='235' y='185' width='50' height='50'/><rect  x='135' y='235' width='50' height='50'/><rect  x='235' y='235' width='50' height='50'/><rect  x='135' y='285' width='50' height='50'/><rect  x='235' y='285' width='50' height='50'/><rect  x='85' y='85' width='50' height='50'/><rect  x='285' y='85' width='50' height='50'/><rect  x='85' y='285' width='50' height='50'/><rect  x='285' y='285' width='50' height='50'/></g></svg>", &haxy, .{ .size = 420, .margin = 0.2, .background = .{ 20, 30, 40, 128 }, .saturation = 0.4, .brightness = 0.3 });
    const pull = hashName("pull");
    try expectSvg("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' style='background-color:rgba(240,240,240,1);'><g style='fill:rgba(38,217,174,1); stroke:rgba(38,217,174,1); stroke-width:0.32;'><rect  x='27' y='7' width='10' height='10'/><rect  x='27' y='17' width='10' height='10'/><rect  x='27' y='37' width='10' height='10'/><rect  x='17' y='27' width='10' height='10'/><rect  x='37' y='27' width='10' height='10'/><rect  x='17' y='37' width='10' height='10'/><rect  x='37' y='37' width='10' height='10'/><rect  x='7' y='37' width='10' height='10'/><rect  x='47' y='37' width='10' height='10'/><rect  x='7' y='47' width='10' height='10'/><rect  x='47' y='47' width='10' height='10'/></g></svg>", &pull, .{});
    const nested = hashName("fossify-ios.contacts-ios");
    try expectSvg("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' style='background-color:rgba(240,240,240,1);'><g style='fill:rgba(217,38,130,1); stroke:rgba(217,38,130,1); stroke-width:0.32;'><rect  x='27' y='7' width='10' height='10'/><rect  x='17' y='7' width='10' height='10'/><rect  x='37' y='7' width='10' height='10'/><rect  x='17' y='17' width='10' height='10'/><rect  x='37' y='17' width='10' height='10'/><rect  x='17' y='37' width='10' height='10'/><rect  x='37' y='37' width='10' height='10'/><rect  x='7' y='27' width='10' height='10'/><rect  x='47' y='27' width='10' height='10'/></g></svg>", &nested, .{});
}

test "identicons are deterministic and differ by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a1 = try tileFor(arena.allocator(), "pull", .{});
    const a2 = try tileFor(arena.allocator(), "pull", .{});
    const b = try tileFor(arena.allocator(), "haxy", .{});
    try std.testing.expectEqualStrings(a1, a2);
    try std.testing.expect(!std.mem.eql(u8, a1, b));
    try std.testing.expect(std.mem.startsWith(u8, a1, "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'"));
    try std.testing.expect(std.mem.indexOf(u8, a1, "<rect class='cpull-identicon-bg' width='64' height='64' rx='8'/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, a1, "<style>") == null);
    const served = try tileFor(arena.allocator(), "pull", .{ .standalone = true, .class = "x" });
    try std.testing.expect(std.mem.indexOf(u8, served, "class='cpull-identicon x'") != null);
    try std.testing.expect(std.mem.indexOf(u8, served, "prefers-color-scheme:dark") != null);
}

test "the grid mirrors around the middle column" {
    const hash = hashName("cpull");
    const icon = try Identicon.init(&hash, .{});
    const cells = icon.grid();
    for (0..5) |row| {
        try std.testing.expectEqual(cells[row * 5 + 0], cells[row * 5 + 4]);
        try std.testing.expectEqual(cells[row * 5 + 1], cells[row * 5 + 3]);
    }
    var buf: [25]Rect = undefined;
    var painted: usize = 0;
    for (cells) |c| painted += @intFromBool(c);
    try std.testing.expectEqual(painted, icon.rects(&buf).len);
}

test "short and non-hex hashes are refused" {
    try std.testing.expectError(error.InvalidHash, Identicon.init("abc", .{}));
    try std.testing.expectError(error.InvalidHash, Identicon.init("0123456789abcdefzzzzzzz", .{}));
}
