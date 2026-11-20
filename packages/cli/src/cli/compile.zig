const std = @import("std");
const Attempt = @import("watch/attempt.zig");
pub const Status = enum { success, failed, retry, backend_failed };

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    /// The caller guarantees `allocator` and its parents are threadsafe.
    concurrent_analysis: bool = false,
    options: @import("options.zig").Options,
    environment: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    watch: ?*Attempt = null,
};

pub const run = @import("compilation/state.zig").run;
