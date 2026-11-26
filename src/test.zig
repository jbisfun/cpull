comptime {
    _ = @import("test/event.zig");
    _ = @import("test/event/admin.zig");
    _ = @import("test/event/notify.zig");
    _ = @import("test/event/patch.zig");
    _ = @import("test/event/stack.zig");
    _ = @import("test/ssh.zig");
    _ = @import("test/ui.zig");
    _ = @import("test/undo.zig");
    _ = @import("test/workspace.zig");
    _ = @import("test/report.zig");
    _ = @import("report/report.zig");
    _ = @import("report/anchor.zig");
    _ = @import("api.zig");
    _ = @import("forge.zig");
    _ = @import("tools/tools.zig");
    _ = @import("pullfile.zig");
    _ = @import("multipart.zig");
    _ = @import("report/web.zig");
    _ = @import("frontend/cpull/frontend.zig");
    _ = @import("frontend/cpull/localtime.zig");
    _ = @import("frontend/cpull/views/repo.zig");
    _ = @import("frontend/cpull/views/admin.zig");
}
