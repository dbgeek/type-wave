//! tests.zig — the `zig build test` root. Pulls in every source file that carries `test`
//! blocks so a single test artifact runs them all (the Coordinator's lifecycle matrix plus
//! the backfilled pure-function tests). Built with the same imports/frameworks as the exe,
//! since these files reference the vendored websocket module and the macOS frameworks even
//! where the tested functions themselves are pure.

test {
    _ = @import("coordinator.zig");
    _ = @import("config.zig");
    _ = @import("session.zig");
    _ = @import("hud.zig");
    _ = @import("insert.zig"); // ensureTrailingSpace (the Insertion separator)
    _ = @import("insertion_adapter.zig");
}
