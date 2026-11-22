const std = @import("std");
const zx = @import("zx");
const owner = @import("../../../project.zig");
const Project = owner.Project;
const project = owner.signature_project;
const Value = @FieldType(project.Result, "value");

const Batch = struct {
    state: *Project,
    registered: bool,
    modules: []project.Module = undefined,
    libraries: []project.Library = undefined,
    iterator: @TypeOf(@as(owner.compiled.imports.Cache, undefined).iterator()) = undefined,
    result: project.Data = undefined,
    fn read(handle: *const anyopaque) *Batch {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(state: *Project, entries: project.Entries, registered: bool) std.mem.Allocator.Error!Value {
    const generated = @import("generated_project_signatures_batch");
    var batch: Batch = .{ .state = state, .registered = registered };

    const count = switch (entries) {
        inline else => |items| items.len,
    };

    const input: std.meta.Child(generated.Input) = .{
        .batch = @ptrCast(&batch),
        .entries = count,
        .units = state.units.len,
        .rows = if (entries == .rows) entries.rows else null,
        .paths = if (entries == .paths) entries.paths else &.{},
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const published = generated.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSource => {
            var issue = state.reporter.diagnostic.?;

            issue.source_index = state.current_source;

            return .{ .diagnostic = issue };
        },
        else => unreachable,
    };

    return if (published)
        .{ .data = batch.result }

    else
        .{ .diagnostic = project.missing_entry };
}

pub fn reserveProjectSignatures(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const batch = Batch.read(handle);
    batch.modules = try batch.state.allocator.alloc(project.Module, @intCast(count));
}

pub fn findProjectSignature(handle: *const anyopaque, name: []const u8) std.mem.Allocator.Error!?u64 {
    const batch = Batch.read(handle);
    const state = batch.state;
    const path = if (batch.registered) name else try std.fs.path.resolve(state.allocator, &.{ state.options.root_dir, name });

    return if (state.options.source_index.?.get(path)) |row| row else null;
}

pub fn loadProjectSignature(handle: *const anyopaque, row: u64) zx.Error!void {
    return Batch.read(handle).state.loadFrames(@intCast(row), .signature);
}

pub fn writeProjectSignature(handle: *const anyopaque, slot: u64, row: u64) void {
    const batch = Batch.read(handle);
    const unit = &batch.state.units[@intCast(row)];

    batch.modules[@intCast(slot)] = .{
        .path = unit.path,
        .source_row = @intCast(row),
        .signature = unit.signature.?,
        .type_imports = unit.signature_aliases,
        .function_imports = unit.signature_imports,
        .reexport_functions = unit.signature_reexports,
        .constant_imports = unit.signature_constant_imports,
    };
}

pub fn reserveProjectLibraries(handle: *const anyopaque) std.mem.Allocator.Error!u64 {
    const batch = Batch.read(handle);
    const units = &batch.state.compiled_units;
    const count = units.count();
    batch.libraries = try batch.state.allocator.alloc(project.Library, count);
    batch.iterator = units.iterator();

    return count;
}

pub fn writeProjectLibrary(handle: *const anyopaque, slot: u64) void {
    const batch = Batch.read(handle);
    const entry = batch.iterator.next().?;

    batch.libraries[@intCast(slot)] = .{ .index = entry.key_ptr.*, .unit = entry.value_ptr.* };
}

pub fn finishProjectSignatures(handle: *const anyopaque) void {
    const batch = Batch.read(handle);
    const state = batch.state;

    batch.result = .{
        .types = state.types.view(),
        .nominal_types = state.nominal_origins.items.view(),
        .native_modules = state.native_modules.view(),
        .functions = state.functions.view(),
        .store_initializers = state.store_initializers.items,
        .modules = batch.modules,
        .libraries = batch.libraries,
    };
}
