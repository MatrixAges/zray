const std = @import("std");
const memory = @import("zx").memory;
const compiled = @import("../compiled.zig");
const Index = @import("imports/index.zig");
const Destination = @import("load.zig").Destination;
const Project = @import("../project.zig").Options;
pub const Initializers = std.ArrayList(compiled.StoreInitializer);
pub const Error = std.mem.Allocator.Error || error{ MissingLibrary, ConflictingArtifact, InvalidLibrary, MissingPublicModule };
const ResolutionError = std.mem.Allocator.Error || error{ MissingLibrary, ConflictingArtifact };

pub const Unit = struct {
    exports: []const compiled.Export,
    names: Index = .{},
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
    project: *const Project,
    target: *const compiled.Target,
    destination: Destination,
    cache: *Cache,
    first: usize,
    rows: memory.RowBuffer = .empty(compiled.StoreInitializer),
    pending: Index = .{},
    exports: []const compiled.Export = &.{},
    names: memory.TextColumn = undefined,
    buckets: []u64 = &.{},
    fn borrow(handle: *anyopaque) *Load {
        return @ptrCast(@alignCast(handle));
    }
    fn useExports(self: *Load, exports: []const compiled.Export, buckets: []u64) u64 {
        self.exports = exports;
        self.names = memory.borrowTextColumn("name", exports);
        self.buckets = buckets;

        return exports.len;
    }
};

pub fn load(allocator: std.mem.Allocator, project: *const Project, target: compiled.Target, destination: Destination, cache: *Cache, initializers: *Initializers) Error!*const compiled.Export {
    if (comptime !@import("parser_options").generated_parser) return @import("imports/seed.zig").load(allocator, project, target, destination, cache, initializers);

    const rule = @import("generated_compiled_import_execute");
    var frame: Load = .{ .allocator = allocator, .project = project, .target = &target, .destination = destination, .cache = cache, .first = initializers.items.len };
    frame.rows.bytes = std.mem.sliceAsBytes(initializers.allocatedSlice());
    const first = frame.first;
    var published = [1]u64{first};
    var used: []u64 = &published;

    defer frame.pending.deinit(allocator);

    defer {
        const rows = frame.rows.rows(compiled.StoreInitializer);

        if (rows.len != 0) {
            initializers.items = rows[0..@intCast(published[0])];
            initializers.capacity = rows.len;
        }
    }

    const input: std.meta.Child(rule.Input) = .{
        .frame = @ptrCast(&frame),
        .owner = @ptrCast(&allocator),
        .initializers = &.{ .rows = @ptrCast(&frame.rows), .owner = @ptrCast(&allocator), .used = @ptrCast(&used), .first = first },
        .index = @ptrCast(&frame.pending.storage),
        .member = &.{ .names = @ptrCast(&frame.names), .buckets = @ptrCast(&frame.buckets), .name = target.name },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const row = rule.executeIn(empty.allocator(), &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.MissingLibrary => error.MissingLibrary,
        error.ConflictingArtifact => error.ConflictingArtifact,
        error.InvalidLibrary => error.InvalidLibrary,
        else => unreachable,
    };

    return &frame.exports[@intCast(row orelse return error.MissingPublicModule)];
}

pub fn resolve(allocator: std.mem.Allocator, project: *const Project, target: compiled.Target) ResolutionError!usize {
    return switch (try compiled.resolve.library(allocator, project.compiled_libraries, project.root_dir, target)) {
        .found => |index| index,
        .conflict => error.ConflictingArtifact,
        .missing => error.MissingLibrary,
    };
}

pub fn resolveCompiledImport(handle: *anyopaque) ResolutionError!u64 {
    const frame = Load.borrow(handle);

    return resolve(frame.allocator, frame.project, frame.target.*);
}

pub fn findCompiledLibrary(handle: *anyopaque, index: u64, inherited: bool) ?u64 {
    const frame = Load.borrow(handle);
    const cache = if (inherited) &frame.cache.inherited else &frame.cache.added;
    const unit = cache.getPtr(@intCast(index)) orelse return null;

    return frame.useExports(unit.exports, unit.names.storage);
}

pub fn reserveCompiledUnit(handle: *anyopaque, index: u64) std.mem.Allocator.Error!u64 {
    const frame = Load.borrow(handle);

    try frame.cache.added.ensureUnusedCapacity(frame.allocator, 1);

    return frame.project.compiled_libraries[@intCast(index)].exports.len;
}

pub fn compiledInitializerCount(handle: *anyopaque, index: u64) u64 {
    return Load.borrow(handle).project.compiled_libraries[@intCast(index)].store_initializers.len;
}

pub fn bindCompiledImport(handle: *anyopaque, index: u64) (std.mem.Allocator.Error || error{InvalidLibrary})!u64 {
    const frame = Load.borrow(handle);
    const library = frame.project.compiled_libraries[@intCast(index)];
    const rows = frame.rows.rows(compiled.StoreInitializer);
    const count = library.store_initializers.len;

    const linked = @import("host/root.zig").load(frame.allocator, library, frame.destination, .{
        .export_buckets = frame.pending.storage,
        .initializer_tail = rows[frame.first..][0..count],
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidLibrary;

    return frame.useExports(linked.exports, frame.pending.storage);
}

pub fn rememberCompiledLibrary(handle: *anyopaque, index: u64) void {
    const frame = Load.borrow(handle);

    frame.cache.added.putAssumeCapacityNoClobber(@intCast(index), .{ .exports = frame.exports, .names = frame.pending });

    frame.pending = .{};
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
