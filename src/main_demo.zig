const cpull = @import("cpull");

pub const std_options_debug_io = cpull.demo.std_options_debug_io;
pub const main = cpull.demo.main;

// the web UI the cpull exe serves: the wiki theme unless built with -Dfrontend=classic
pub const cpull_frontend: cpull.web.Frontend = if (@import("frontend_options").themed) cpull.themed_frontend.frontend else .{};
