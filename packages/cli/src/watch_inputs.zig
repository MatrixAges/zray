pub const Inputs = @import("cli/watch/inputs.zig");
pub const Snapshot = @import("cli/watch/snapshot.zig");
pub const observation = @import("cli/watch/observation/storage.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    observation.registration,
    observation.read,
    observation.scan,
    observation.capture,
}).resolve;
