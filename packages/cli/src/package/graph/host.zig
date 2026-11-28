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
    lock: ?@import("../install/files.zig").Loaded = null,
    installed: []@import("../graph.zig").Package = &.{},
    workspace_packages: ?[]@import("../graph.zig").Package = null,
    pub fn get(handle: *const anyopaque) *Context {
        return @import("../../cli/sources/effects.zig").state(Context, handle);
    }
    pub fn fail(self: *const Context, err: anyerror) Error {
        self.failure.* = err;

        return error.PackageGraphHostFailure;
    }
};
