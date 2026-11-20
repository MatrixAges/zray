const std = @import("std");
const compiler = @import("compiler");
const project = @import("../../project.zig");
const Inputs = @import("watch_inputs").Inputs;
const host = @import("publication_host");
const abi = @import("../../abi.zig");
const layout = @import("../publication/layout.zig");
const resources = @import("../resources.zig");
pub const Error = host.effects.Error;

pub const Request = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    directory: []const u8,
    library: *const compiler.library.Result,
    bundle: *const compiler.zig.LibraryBundle,
    loaded: *const project.Loaded,
    inputs: ?*Inputs,
};

pub const State = struct {
    request: Request,
    resources: *const resources.State,
    failure: *host.Failure,
    abi: abi.Result = undefined,
    layout: layout.Plan = undefined,
    config: project.Config = undefined,
    managed: []const host.inventory.File = &.{},
    pub fn get(handle: *const anyopaque) *State {
        return host.effects.state(State, handle);
    }
};
