const std = @import("std");
const compiler = @import("compiler");
const resolve = compiler.project.compiled.resolve;
const Inputs = @import("watch_inputs").Inputs;
const Self = @This();

allocator: std.mem.Allocator,
libraries: std.ArrayList(compiler.project.compiled.Library) = .empty,
owned: std.ArrayList(compiler.library.codec.Indexed) = .empty,
failure_path: ?[]const u8 = null,
pub fn deinit(self: *Self) void {
    for (self.owned.items) |*entry| entry.library.deinit();

    self.owned.deinit(self.allocator);
    self.libraries.deinit(self.allocator);

    self.* = undefined;
}

pub fn add(self: *Self, io: std.Io, target: compiler.project.compiled.Target, project: compiler.project.Options, inputs: ?*Inputs) !*const compiler.library.Export {
    self.failure_path = null;
    errdefer self.failure_path = target.artifact;

    switch (resolve.cached(self.libraries.items, target)) {
        .found => |index| return requireExport(&self.owned.items[index], target.name),
        .conflict => return error.ConflictingLibraryArtifact,
        .missing => {},
    }

    var decoded = try @import("artifact.zig").openIndexed(self.allocator, .{
        .io = io,
        .path = target.artifact,
        .scopes = project.package_scopes,
        .inputs = inputs,
    });

    errdefer decoded.library.deinit();

    const exported = try requireExport(&decoded, target.name);
    const library = &decoded.library;

    try self.libraries.ensureUnusedCapacity(self.allocator, 1);
    try self.owned.append(self.allocator, decoded);

    self.libraries.appendAssumeCapacity(.{ .instance = target.instance, .artifact = target.artifact, .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types, .store_initializers = library.store_initializers });

    return exported;
}

fn requireExport(decoded: *const compiler.library.codec.Indexed, name: []const u8) error{MissingPublicModule}!*const compiler.library.Export {
    const exports = decoded.library.exports;
    const index = decoded.names.find(exports, name) orelse return error.MissingPublicModule;

    return &exports[index];
}
