const std = @import("std");
const zx = @import("zx");
const compiled = @import("../compiled.zig");
const Names = @import("../source_index.zig").Map;
const Destination = @import("load.zig").Destination;
const Initializers = std.ArrayList(compiled.StoreInitializer);
const generated = @import("parser_options").generated_parser;
const Index = if (generated) []u64 else Names;
pub const Error = std.mem.Allocator.Error || error{ MissingLibrary, ConflictingArtifact, InvalidLibrary, MissingPublicModule };

pub const Unit = struct {
    exports: []const compiled.Export,
    names: Index = if (generated) &.{} else .empty,
    fn find(self: *const Unit, name: []const u8) ?*const compiled.Export {
        if (comptime generated) {
            const rule = @import("generated_compiled_import_find");
            const Input = std.meta.Child(rule.Input);
            const names = zx.memory.borrowTextColumn("name", self.exports);
            const buckets: []u64 = self.names;

            const input: Input = .{
                .names = @ptrCast(&names),
                .buckets = @ptrCast(&buckets),
                .capacity = buckets.len,
                .count = self.exports.len,
                .name = name,
            };

            var scratch = std.heap.FixedBufferAllocator.init(&.{});
            const row = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

            return if (row) |index| &self.exports[@intCast(index)] else null;
        }

        if (self.exports.len == 1) {
            const exported = &self.exports[0];

            return if (zx.bytes.equal(exported.name, name)) exported else null;
        }

        const index = self.names.get(name) orelse return null;

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

    const count = if (library.exports.len > 1) library.exports.len else 0;
    const names = if (comptime generated) try Names.bucketsFor(allocator, count) else try Names.init(allocator, count);

    const linked = (if (comptime generated)
        @import("host/root.zig").load(allocator, library.*, destination, names)
    else
        compiled.loadInto(allocator, library.*, destination)) catch |err| {
        if (comptime generated) allocator.free(names) else names.deinit(allocator);
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return error.InvalidLibrary;
    };

    var unit: Unit = .{ .exports = linked.exports, .names = names };

    if (comptime !generated) {
        if (linked.exports.len > 1) for (linked.exports, 0..) |*exported, row| {
            const inserted = unit.names.claim(row, exported.name);

            std.debug.assert(inserted);
        };
    }

    initializers.appendSliceAssumeCapacity(linked.store_initializers);
    cache.putAssumeCapacity(index, unit);

    return unit.find(target.name) orelse error.MissingPublicModule;
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
