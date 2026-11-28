const std = @import("std");
const workspace = @import("../workspace.zig");
const Inputs = @import("watch_inputs").Inputs;
pub const Error = error{PackageGraphHostFailure};

pub const Context = struct {
    io: std.Io,
    members: []const workspace.Package,
    inputs: ?*Inputs,
    manifests: std.mem.Allocator,
    backing: std.mem.Allocator,
    failure: *?anyerror,
    pub fn get(handle: *const anyopaque) *const Context {
        return @ptrCast(@alignCast(handle));
    }

    pub fn fail(self: *const Context, err: anyerror) Error {
        self.failure.* = err;

        return error.PackageGraphHostFailure;
    }
};
