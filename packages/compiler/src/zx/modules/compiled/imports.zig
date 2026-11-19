const std = @import("std");
const compiled = @import("../compiled.zig");
const Index = @import("imports/index.zig");
const Destination = @import("load.zig").Destination;
const Initializers = std.ArrayList(compiled.StoreInitializer);
const generated = @import("parser_options").generated_parser;
pub const Error = std.mem.Allocator.Error || error{ MissingLibrary, ConflictingArtifact, InvalidLibrary, MissingPublicModule };

pub const Unit = struct {
    exports: []const compiled.Export,
    names: Index = .{},
    fn find(self: *const Unit, name: []const u8) ?*const compiled.Export {
        const index = self.names.find(self.exports, name) orelse return null;

        return &self.exports[index];
    }
};

pub const Cache = std.AutoHashMapUnmanaged(usize, Unit);

pub fn load(allocator: std.mem.Allocator, project: *const @import("../project.zig").Options, target: compiled.Target, destination: Destination, cache: *Cache, initializers: *Initializers) Error!*const compiled.Export {
    const index = switch (try compiled.resolve.library(allocator, project.compiled_libraries, project.root_dir, target)) {
        .found => |value| value,
        .conflict => return error.ConflictingArtifact,
        .missing => return error.MissingLibrary,
    };

    if (cache.getPtr(index)) |unit| return unit.find(target.name) orelse error.MissingPublicModule;
    try cache.ensureUnusedCapacity(allocator, 1);

    const library = &project.compiled_libraries[index];

    try initializers.ensureUnusedCapacity(allocator, library.store_initializers.len);

    const staged = prepare: {
        const names = try Index.init(allocator, library.exports.len);

        errdefer names.deinit(allocator);

        const linked = (if (comptime generated)
            @import("host/root.zig").load(allocator, library.*, destination, names.buckets())
        else
            compiled.loadInto(allocator, library.*, destination)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return error.InvalidLibrary;
        };

        var unit: Unit = .{ .exports = linked.exports, .names = names };

        try unit.names.finish(linked.exports);

        break :prepare .{ .unit = unit, .initializers = linked.store_initializers };
    };

    initializers.appendSliceAssumeCapacity(staged.initializers);
    cache.putAssumeCapacity(index, staged.unit);

    // A missing requested name still leaves the successfully loaded library cached.
    return staged.unit.find(target.name) orelse error.MissingPublicModule;
}

pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.MissingLibrary => "compiled library is missing from the input set",
        error.ConflictingArtifact => "compiled package instance has conflicting artifacts",
        error.InvalidLibrary => "compiled library has invalid IR or conflicting identities",
        error.MissingPublicModule => "compiled library does not export this public module",
        error.OutOfMemory => unreachable,
    };
}
