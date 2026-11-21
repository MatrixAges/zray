const std = @import("std");
const zx = @import("zx");
const compiled = @import("../compiled.zig");
const Index = @import("imports/index.zig");
const Destination = @import("load.zig").Destination;
const Initializers = std.ArrayList(compiled.StoreInitializer);
const generated = @import("parser_options").generated_parser;
const Resolution = if (generated) @import("project_execution_abi").layouts.@"zig:project_host".LibraryResolution else enum { Found, Missing, Conflict };
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

const Load = struct {
    allocator: std.mem.Allocator,
    project: *const @import("../project.zig").Options,
    target: *const compiled.Target,
    destination: Destination,
    cache: *Cache,
    initializers: *Initializers,
    index: usize = undefined,
    names: ?Index = null,
    staged: Unit = undefined,
    staged_initializers: []const compiled.StoreInitializer = undefined,
    unit: *const Unit = undefined,
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
            .MissingLibrary => return error.MissingLibrary,
            .ConflictingArtifact => return error.ConflictingArtifact,
            .InvalidLibrary => return error.InvalidLibrary,
            .MissingPublicModule => return error.MissingPublicModule,
            .Reused, .NeedsLink => unreachable,
        }
    } else try seed(&frame);

    return frame.result;
}

fn seed(frame: *Load) Error!void {
    switch (try resolveCompiledImport(frame)) {
        .Found => {},
        .Missing => return error.MissingLibrary,
        .Conflict => return error.ConflictingArtifact,
    }

    if (!reuseCompiledLibrary(frame)) {
        try reserveCompiledImport(frame);
        if (!try bindCompiledImport(frame)) return error.InvalidLibrary;

        publishCompiledInitializers(frame);
        rememberCompiledLibrary(frame);
    }

    if (!selectCompiledMember(frame)) return error.MissingPublicModule;
}

pub fn resolveCompiledImport(handle: *const anyopaque) std.mem.Allocator.Error!Resolution {
    const frame = Load.borrow(handle);

    return switch (try compiled.resolve.library(frame.allocator, frame.project.compiled_libraries, frame.project.root_dir, frame.target.*)) {
        .found => |index| found: {
            frame.index = index;

            break :found .Found;
        },
        .conflict => .Conflict,
        .missing => .Missing,
    };
}

pub fn reuseCompiledLibrary(handle: *const anyopaque) bool {
    const frame = Load.borrow(handle);

    frame.unit = frame.cache.getPtr(frame.index) orelse return false;

    return true;
}

pub fn reserveCompiledImport(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Load.borrow(handle);
    const library = &frame.project.compiled_libraries[frame.index];

    try frame.cache.ensureUnusedCapacity(frame.allocator, 1);
    try frame.initializers.ensureUnusedCapacity(frame.allocator, library.store_initializers.len);

    const names = try Index.init(frame.allocator, library.exports.len);

    frame.names = names;
}

pub fn bindCompiledImport(handle: *const anyopaque) std.mem.Allocator.Error!bool {
    const frame = Load.borrow(handle);
    const library = &frame.project.compiled_libraries[frame.index];

    const linked = (if (comptime generated)
        @import("host/root.zig").load(frame.allocator, library.*, frame.destination, frame.names.?.buckets())
    else
        compiled.loadInto(frame.allocator, library.*, frame.destination)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };

    frame.names.?.finish(linked.exports) catch return false;

    frame.staged = .{ .exports = linked.exports, .names = frame.names.? };
    frame.staged_initializers = linked.store_initializers;

    return true;
}

pub fn publishCompiledInitializers(handle: *const anyopaque) void {
    const frame = Load.borrow(handle);

    frame.initializers.appendSliceAssumeCapacity(frame.staged_initializers);
}

pub fn rememberCompiledLibrary(handle: *const anyopaque) void {
    const frame = Load.borrow(handle);
    const slot = frame.cache.getOrPutAssumeCapacity(frame.index);
    slot.value_ptr.* = frame.staged;
    frame.unit = slot.value_ptr;
    frame.names = null;
}

pub fn selectCompiledMember(handle: *const anyopaque) bool {
    const frame = Load.borrow(handle);

    frame.result = frame.unit.find(frame.target.name) orelse return false;

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
