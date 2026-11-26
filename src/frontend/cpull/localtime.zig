// the server's local time for the themed pages, through libc's localtime_r
// (the zone from TZ, else /etc/localtime; SQLite and tree-sitter already link
// libc, and src/ci/fmt.zig reads its local times the same way). the workspace
// server runs on the user's own machine, so its zone is the reader's.
const std = @import("std");

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;

// "2026-11-25 14:05 EST", or null when libc can't place the time
pub fn format(aa: std.mem.Allocator, secs: i64) !?[]const u8 {
    var tm: Tm = undefined;
    const t: c_long = std.math.cast(c_long, secs) orelse return null;
    _ = localtime_r(&t, &tm) orelse return null;
    const zone = if (tm.zone) |z| std.mem.span(z) else "";
    return try aa.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}{s}{s}", .{
        @as(u32, @intCast(tm.year + 1900)),
        @as(u32, @intCast(tm.mon + 1)),
        @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
        if (zone.len > 0) " " else "",
        zone,
    });
}

// "2026-11-25 19:05:00 UTC"
pub fn utc(aa: std.mem.Allocator, secs: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const day = seconds.getDaySeconds();
    return aa.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ year.year, month.month.numeric(), month.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

test utc {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-11-25 19:05:00 UTC", try utc(arena.allocator(), 1795633500));
    // whatever the zone, the local form has a date and a time
    const local = (try format(arena.allocator(), 1795633500)).?;
    try std.testing.expect(local.len >= "2026-11-25 19:05".len);
}
