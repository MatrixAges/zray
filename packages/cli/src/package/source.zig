const std = @import("std");
const compiler = @import("compiler");
const Inputs = @import("watch_inputs").Inputs;
const rules = @import("cli_source");
const Registration = @import("watch_inputs").observation.registration.Context;

pub fn validate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, scopes: []const compiler.project.PackageScope) !void {
    return validateWithInputs(io, allocator, path, scopes, null);
}

pub fn validateWithInputs(io: std.Io, allocator: std.mem.Allocator, path: []const u8, scopes: []const compiler.project.PackageScope, inputs: ?*Inputs) !void {
    if (scopes.len == 0) return;

    var registration: Registration = if (inputs) |observed| .{ .io = io, .inputs = observed } else undefined;
    const reference = &registration;
    const owner = compiler.project.package_scope.owner(scopes, path);

    const status = rules.workspace_source.executeIn(allocator, &.{
        .registration = if (inputs != null) @ptrCast(&reference) else null,
        .path = path,
        .root = if (owner) |index| scopes[index].root else null,
    }, io) catch |err| return if (err == error.ObservationFailure) registration.failure.? else err;

    switch (status) {
        .Valid => {},
        .Outside => return error.UndeclaredPackageSource,
        .Alias => return error.PackageSourceMustUsePhysicalPath,
        .Undeclared => return error.SourceBelongsToUndeclaredPackage,
    }
}

pub fn hasPackageManifest(io: std.Io, path: []const u8) std.Io.Dir.AccessError!bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}
