//! cpull's CI: a Zig port of idlci (local CI for the idl projects of a pull
//! workspace) running inside the workspace server. A SQLite job queue
//! (`.pull/cpull/ci/ci.db`, idlci's schema), executor threads running `idl
//! build|test|lint|fmt --check|check|clean` as process groups, `--ci-watch`
//! HEAD polling, Jenkins-style pages and a JSON API under /ci, and the `cpull
//! ci` CLI. pull's MCP ci_* tools talk to the same API.
const std = @import("std");

pub const db = @import("db.zig");
pub const projects = @import("projects.zig");
pub const app = @import("app.zig");
pub const web = @import("web.zig");
pub const cli = @import("cli.zig");
pub const work = @import("work.zig");

pub const App = app.App;
pub const Options = app.Options;

test {
    _ = db;
    _ = projects;
    _ = @import("fmt.zig");
    _ = work;
    _ = @import("test.zig");
}
