const abi = @import("watch_observation_abi").native.@"zig:snapshot_host";
pub const Admission = abi.Admission;
pub const PathKind = abi.PathKind;
pub const Error = error{ObservationFailure};
pub const registration = @import("registration.zig");
pub const capture = @import("capture.zig");
pub const scan = @import("scan.zig");
pub const read = @import("read.zig");
