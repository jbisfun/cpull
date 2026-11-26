// SIGTERM/SIGINT for the workspace server: CI jobs run in process groups of
// their own (so cancel can kill their compilers), which also means they
// outlive a server that is simply killed. The handler only flags the signal;
// a watcher thread then stops the workers, SIGTERMs every running job's
// process group (SIGKILL after a grace period; the jobs are recorded as
// cancelled), and re-raises the signal with its default action, so the
// server dies of it as before. A second signal exits at once.
const std = @import("std");
const linux = std.os.linux;
const ci_app = @import("../ci/app.zig");

const App = ci_app.App;
const log = std.log.scoped(.integrate);

// seconds the jobs get to finish after SIGTERM before SIGKILL
pub const grace_s = 5;

var signalled: std.atomic.Value(u8) = .init(0);
var installed = false;

fn handler(sig: std.posix.SIG) callconv(.c) void {
    if (signalled.swap(@intCast(@intFromEnum(sig)), .acq_rel) != 0) linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
}

pub fn install(app: *App) void {
    if (installed) return;
    installed = true;
    const t = std.Thread.spawn(.{}, watch, .{app}) catch |e| {
        log.err("can't watch for SIGTERM: {t}", .{e});
        return;
    };
    t.detach();
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
    // a pull job's pty closing hangs it up
    std.posix.sigaction(.HUP, &act, null);
}

fn watch(app: *App) void {
    while (signalled.load(.acquire) == 0) app.io.sleep(.fromMilliseconds(100), .awake) catch {};
    const sig: std.posix.SIG = @enumFromInt(signalled.load(.acquire));
    log.info("{t}: cancelling the running CI jobs", .{sig});
    if (app.workers) app.runner.shutdown(grace_s);
    // die of the signal, as without the handler
    const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = null }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(sig, &dfl, null);
    _ = linux.kill(linux.getpid(), sig);
    linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
}
