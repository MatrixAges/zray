const std = @import("std");
const ir = @import("ir.zig");
const Index = @import("terms/index.zig");
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{InvalidHardwareTerm};

allocator: std.mem.Allocator,
scratch: std.mem.Allocator,
variables: Index = .empty,
cache: Index = .empty,
origin: ?ir.Origin = null,
pub fn fromSourceError(err: error{ OutOfMemory, IndexOutOfBounds, IntegerOverflow }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexOutOfBounds, error.IntegerOverflow => error.InvalidHardwareTerm,
    };
}
