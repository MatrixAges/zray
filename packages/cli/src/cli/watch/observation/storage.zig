const abi = @import("cli_abi");
pub const Slot = abi.layouts.@"zig:snapshot_host".Slot;
pub const PathKind = abi.native.@"zig:snapshot_host".PathKind;
pub const Reuse = abi.native.@"zig:snapshot_host".Reuse;
pub const Error = error{ObservationFailure};
pub const registration = @import("registration.zig");
pub const capture = @import("capture.zig");
pub const scan = @import("scan.zig");
pub const read = @import("read.zig");
pub const directory = @import("directory/host.zig");

// The ABI borrows the handle. Its target remains writable across Source calls.
pub fn context(comptime Context: type, handle: *const anyopaque) *Context {
    return @as(*const *Context, @ptrCast(@alignCast(handle))).*;
}
