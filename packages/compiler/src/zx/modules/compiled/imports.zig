const std = @import("std");
const memory = @import("zx").memory;
const compiled = @import("../compiled.zig");
const Index = @import("imports/index.zig");
const Destination = @import("load.zig").Destination;
const Project = @import("../project.zig").Options;
const generated = @import("parser_options").generated_parser;
const Rule = if (generated) @import("generated_compiled_import_execute") else void;
const Input = if (generated) std.meta.Child(Rule.Input) else void;
const Result = if (generated) @typeInfo(@TypeOf(Rule.executeIn(undefined, undefined))).error_union.payload else void;
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

pub fn load(allocator: std.mem.Allocator, project: *const Project, target: compiled.Target, destination: Destination, cache: *Cache, initializers: *Initializers) Error!*const compiled.Export {
    if (comptime !generated) return @import("imports/seed.zig").load(allocator, project, target, destination, cache, initializers);

    const index = try resolve(allocator, project, target);
    const inherited = cache.inherited.getPtr(index);
    var added: ?*const Unit = cache.added.getPtr(index);

    if (added == null and inherited == null) {
        added = try install(allocator, index, &project.compiled_libraries[index], destination, &cache.added, initializers);
    }

    const added_names = if (added) |unit| memory.borrowTextColumn("name", unit.exports) else undefined;
    const inherited_names = if (inherited) |unit| memory.borrowTextColumn("name", unit.exports) else undefined;
    const Member = std.meta.Child(@typeInfo(@FieldType(Input, "added")).optional.child);
    const added_member = if (added) |unit| unit.names.borrow(Member, &added_names, target.name) else null;
    const inherited_member = if (inherited) |unit| unit.names.borrow(Member, &inherited_names, target.name) else null;
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);

    const result = try execute(scratch.allocator(), &.{
        .added = if (added_member) |*member| member else null,
        .inherited = if (inherited_member) |*member| member else null,
        .initializers = null,
    });

    const unit = if (result.inherited) inherited.? else added.?;

    return &unit.exports[@intCast(result.row orelse return error.MissingPublicModule)];
}

pub fn resolve(allocator: std.mem.Allocator, project: *const Project, target: compiled.Target) ResolutionError!usize {
    return switch (try compiled.resolve.library(allocator, project.compiled_libraries, project.root_dir, target)) {
        .found => |index| index,
        .conflict => error.ConflictingArtifact,
        .missing => error.MissingLibrary,
    };
}

fn install(allocator: std.mem.Allocator, index: usize, library: *const compiled.Library, destination: Destination, cache: *Snapshot, initializers: *Initializers) (std.mem.Allocator.Error || error{InvalidLibrary})!*const Unit {
    try cache.ensureUnusedCapacity(allocator, 1);

    const names = try Index.init(allocator, library.exports.len);

    errdefer names.deinit(allocator);

    var buffer: memory.RowBuffer = .empty(compiled.StoreInitializer);
    buffer.bytes = std.mem.sliceAsBytes(initializers.allocatedSlice());
    const first = initializers.items.len;
    const count = library.store_initializers.len;
    var published = first;

    defer {
        const rows = buffer.rows(compiled.StoreInitializer);

        if (rows.len != 0) {
            initializers.items = rows[0..published];
            initializers.capacity = rows.len;
        }
    }

    var scratch_buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);

    const reserved = try execute(scratch.allocator(), &.{
        .added = null,
        .inherited = null,
        .initializers = &.{ .rows = @ptrCast(&buffer), .owner = @ptrCast(&allocator), .first = first, .count = count },
    });

    const rows = buffer.rows(compiled.StoreInitializer);

    const linked = @import("host/root.zig").load(allocator, library.*, destination, .{
        .export_buckets = names.storage,
        .initializer_tail = rows[first..][0..count],
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidLibrary;

    const added = cache.getOrPutAssumeCapacity(index);

    std.debug.assert(!added.found_existing);

    added.value_ptr.* = .{ .exports = linked.exports, .names = names };
    published = @intCast(reserved.published.?);

    return added.value_ptr;
}

fn execute(allocator: std.mem.Allocator, input: *const Input) std.mem.Allocator.Error!Result {
    return Rule.executeIn(allocator, input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
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
