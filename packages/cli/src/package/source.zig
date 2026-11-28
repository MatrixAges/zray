const std = @import("std");
const compiler = @import("compiler");
const Inputs = @import("watch_inputs").Inputs;
const rules = @import("cli_source");
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;

const State = struct {
    io: std.Io,
    inputs: ?*Inputs,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

pub fn validate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, scopes: []const compiler.project.PackageScope) !void {
    return validateWithInputs(io, allocator, path, scopes, null);
}

pub fn validateWithInputs(io: std.Io, allocator: std.mem.Allocator, path: []const u8, scopes: []const compiler.project.PackageScope, inputs: ?*Inputs) !void {
    if (scopes.len == 0) return;

    var state: State = .{
        .io = io,
        .inputs = inputs,
    };

    const owner = compiler.project.package_scope.owner(scopes, path);
    const reference = &state;
    const status = rules.workspace_source.executeIn(allocator, &.{ .source = @ptrCast(&reference), .path = path, .root = if (owner) |index| scopes[index].root else null }, io) catch |err| return state.failure.unwrap(err);

    switch (status) {
        .Valid => {},
        .Outside => return error.UndeclaredPackageSource,
        .Alias => return error.PackageSourceMustUsePhysicalPath,
        .Undeclared => return error.SourceBelongsToUndeclaredPackage,
    }
}

pub fn hasPackageManifest(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = State.get(handle);

    if (self.inputs) |observed| observed.add(self.io, path) catch |err| return self.failure.save(err);

    std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.failure.save(err),
    };

    return true;
}
