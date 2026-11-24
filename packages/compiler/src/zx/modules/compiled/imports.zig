const std = @import("std");
const compiled = @import("../compiled.zig");
const Index = @import("imports/index.zig");
const Destination = @import("load.zig").Destination;
const Initializers = std.ArrayList(compiled.StoreInitializer);
const generated = @import("parser_options").generated_parser;
const UnitHandle = if (generated) @import("project_execution_abi").layouts.@"zig:project_host".CompiledUnit else anyopaque;
pub const Error = std.mem.Allocator.Error || error{ MissingLibrary, ConflictingArtifact, InvalidLibrary, MissingPublicModule };
const ResolutionError = std.mem.Allocator.Error || error{ MissingLibrary, ConflictingArtifact };

pub const Unit = struct {
    exports: []const compiled.Export,
    names: Index = .{},
    fn find(self: *const Unit, name: []const u8) ?*const compiled.Export {
        const index = self.names.find(self.exports, name) orelse return null;

        return &self.exports[index];
    }
};

pub const Snapshot = std.AutoHashMapUnmanaged(usize, Unit);

pub const Cache = struct {
    inherited: Snapshot = .empty,
    added: Snapshot = .empty,
    pub const empty: Cache = .{};

    pub fn count(self: *const Cache) usize {
        return @as(usize, self.inherited.count()) + self.added.count();
    }
};

const Load = struct {
    allocator: std.mem.Allocator,
    project: *const @import("../project.zig").Options,
    target: *const compiled.Target,
    destination: Destination,
    cache: *Cache,
    initializers: *Initializers,
    names: ?Index = null,
    exports: []const compiled.Export = undefined,
    staged_initializers: []const compiled.StoreInitializer = undefined,
    result: *const compiled.Export = undefined,
    fn borrow(handle: *const anyopaque) *Load {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn load(allocator: std.mem.Allocator, project: *const @import("../project.zig").Options, target: compiled.Target, destination: Destination, cache: *Cache, initializers: *Initializers) Error!*const compiled.Export {
    var frame: Load = .{
        .allocator = allocator,
        .project = project,
        .target = &target,
        .destination = destination,
        .cache = cache,
        .initializers = initializers,
    };

    defer if (frame.names) |names| names.deinit(allocator);

    if (comptime generated) {
        const rule = @import("generated_compiled_import_execute");
        const input: rule.Input = @ptrCast(&frame);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        switch (try rule.executeIn(empty.allocator(), input)) {
            .Ready => {},
            .InvalidLibrary => return error.InvalidLibrary,
            .MissingPublicModule => return error.MissingPublicModule,
        }
    } else try seed(&frame);

    return frame.result;
}

fn seed(frame: *Load) Error!void {
    const index = try resolveCompiledImport(frame);

    const unit = findCompiledLibrary(frame, index, false) orelse findCompiledLibrary(frame, index, true) orelse new: {
        try reserveCompiledImport(frame, index);

        if (!try bindCompiledImport(frame, index)) return error.InvalidLibrary;

        publishCompiledInitializers(frame);

        break :new rememberCompiledLibrary(frame, index);
    };

    if (!selectCompiledMember(frame, unit)) return error.MissingPublicModule;
}

pub fn resolveCompiledImport(handle: *const anyopaque) ResolutionError!u64 {
    const frame = Load.borrow(handle);

    return switch (try compiled.resolve.library(frame.allocator, frame.project.compiled_libraries, frame.project.root_dir, frame.target.*)) {
        .found => |index| index,
        .conflict => error.ConflictingArtifact,
        .missing => error.MissingLibrary,
    };
}

pub fn findCompiledLibrary(handle: *const anyopaque, index: u64, inherited: bool) ?*const UnitHandle {
    const cache = Load.borrow(handle).cache;
    const table = if (inherited) &cache.inherited else &cache.added;

    return if (table.getPtr(@intCast(index))) |unit| @ptrCast(unit) else null;
}

pub fn reserveCompiledImport(handle: *const anyopaque, index: u64) std.mem.Allocator.Error!void {
    const frame = Load.borrow(handle);
    const library = &frame.project.compiled_libraries[@intCast(index)];

    try frame.cache.added.ensureUnusedCapacity(frame.allocator, 1);

    const initializers = frame.initializers;
    const needed = std.math.add(usize, initializers.items.len, library.store_initializers.len) catch return error.OutOfMemory;

    // Published prefixes live until the owner's arena is released.
    if (needed > initializers.capacity) {
        var grown = try Initializers.initCapacity(frame.allocator, Initializers.growCapacity(needed));

        grown.appendSliceAssumeCapacity(initializers.items);

        initializers.* = grown;
    }

    const names = try Index.init(frame.allocator, library.exports.len);

    frame.names = names;
}

pub fn bindCompiledImport(handle: *const anyopaque, index: u64) std.mem.Allocator.Error!bool {
    const frame = Load.borrow(handle);
    const library = &frame.project.compiled_libraries[@intCast(index)];

    const linked = (if (comptime generated)
        @import("host/root.zig").load(frame.allocator, library.*, frame.destination, frame.names.?.buckets())
    else
        compiled.loadInto(frame.allocator, library.*, frame.destination)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };

    frame.names.?.finish(linked.exports) catch return false;

    frame.exports = linked.exports;
    frame.staged_initializers = linked.store_initializers;

    return true;
}

pub fn publishCompiledInitializers(handle: *const anyopaque) void {
    const frame = Load.borrow(handle);

    frame.initializers.appendSliceAssumeCapacity(frame.staged_initializers);
}

pub fn rememberCompiledLibrary(handle: *const anyopaque, index: u64) *const UnitHandle {
    const frame = Load.borrow(handle);
    const slot = frame.cache.added.getOrPutAssumeCapacity(@intCast(index));

    std.debug.assert(!slot.found_existing);

    slot.value_ptr.* = .{ .exports = frame.exports, .names = frame.names.? };
    frame.names = null;

    return @ptrCast(slot.value_ptr);
}

pub fn selectCompiledMember(handle: *const anyopaque, library: *const anyopaque) bool {
    const frame = Load.borrow(handle);
    const unit: *const Unit = @ptrCast(@alignCast(library));
    frame.result = unit.find(frame.target.name) orelse return false;

    return true;
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
