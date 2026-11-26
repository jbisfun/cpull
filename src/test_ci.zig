// the CI's tests (src/ci), rooted here so they can reach the theme layer
test {
    _ = @import("ci/ci.zig");
    _ = @import("integrate/integrate.zig");
}
