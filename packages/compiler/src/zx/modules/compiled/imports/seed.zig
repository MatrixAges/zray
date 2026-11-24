const std = @import("std");
const imports = @import("../imports.zig");
const compiled = @import("../../compiled.zig");
const Index = @import("index.zig");
const Destination = @import("../load.zig").Destination;
const Project = @import("../../project.zig").Options;
const Initializers = imports.Initializers;

pub fn load(allocator: std.mem.Allocator, project: *const Project, target: compiled.Target, destination: Destination, cache: *imports.Cache, initializers: *Initializers) imports.Error!*const compiled.Export {
    const index = try imports.resolve(allocator, project, target);
    const unit = cache.added.getPtr(index) orelse cache.inherited.getPtr(index) orelse try install(allocator, index, project.compiled_libraries[index], destination, &cache.added, initializers);
    const row = unit.names.find(unit.exports, target.name) orelse return error.MissingPublicModule;

    return &unit.exports[row];
}

fn install(allocator: std.mem.Allocator, index: usize, library: compiled.Library, destination: Destination, cache: *imports.Snapshot, initializers: *Initializers) (std.mem.Allocator.Error || error{InvalidLibrary})!*imports.Unit {
    try cache.ensureUnusedCapacity(allocator, 1);

    const needed = std.math.add(usize, initializers.items.len, library.store_initializers.len) catch return error.OutOfMemory;

    if (needed > initializers.capacity) {
        var grown = try Initializers.initCapacity(allocator, Initializers.growCapacity(needed));

        grown.appendSliceAssumeCapacity(initializers.items);

        initializers.* = grown;
    }

    var names = try Index.init(allocator, library.exports.len);

    errdefer names.deinit(allocator);

    const linked = compiled.loadInto(allocator, library, destination) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidLibrary;

    try names.finish(linked.exports);

    initializers.appendSliceAssumeCapacity(linked.store_initializers);

    const slot = cache.getOrPutAssumeCapacity(index);

    std.debug.assert(!slot.found_existing);

    slot.value_ptr.* = .{ .exports = linked.exports, .names = names };

    return slot.value_ptr;
}
