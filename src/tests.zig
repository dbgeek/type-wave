//! tests.zig — the `zig build test` root. Pulls in every source file that carries `test`
//! blocks so a single test artifact runs them all (the Coordinator's lifecycle matrix plus
//! the backfilled pure-function tests). Built with the same imports/frameworks as the exe,
//! since these files reference the vendored websocket module and the macOS frameworks even
//! where the tested functions themselves are pure.

test {
    _ = @import("coordinator.zig");
    _ = @import("transcription_backend.zig");
    _ = @import("backend_router.zig");
    _ = @import("segmenter.zig");
    _ = @import("local_backend.zig");
    _ = @import("whisper_ipc.zig");
    _ = @import("whisper_helper_core.zig");
    _ = @import("whisper_supervisor.zig");
    _ = @import("config.zig");
    _ = @import("session.zig");
    _ = @import("hud.zig");
    _ = @import("insert.zig"); // ensureTrailingSpace (the Insertion separator)
    _ = @import("insertion_adapter.zig");
    _ = @import("readiness.zig");
    _ = @import("configuration_phase.zig");
    _ = @import("grant_sequence.zig"); // the serialized cold-start TCC request sequence (#130)
    _ = @import("model_store.zig");
    _ = @import("local_model_recovery.zig");
    _ = @import("status_item.zig");
    _ = @import("failure_observation.zig");
    _ = @import("menu.zig");
    _ = @import("operation_channel.zig");
    _ = @import("model_operation.zig"); // the Model Operation Runner (observation + orchestration)
    _ = @import("daemon.zig"); // the capstone: compiled here for coverage (its Model Operation observation tests moved to model_operation.zig)
}
