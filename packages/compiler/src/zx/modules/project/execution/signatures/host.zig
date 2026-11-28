const std = @import("std");
const zx = @import("zx");
const owner = @import("../../../project.zig");
const Project = owner.Project;
const project = owner.signature_project;
const Value = @FieldType(project.Result, "value");

const Batch = struct {
    state: *Project,
    modules: []project.Module = undefined,
    result: project.Data = undefined,
    fn read(handle: *anyopaque) *Batch {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(state: *Project, entries: project.Entries, registered: bool) std.mem.Allocator.Error!Value {
    const generated = @import("generated_project_signatures_batch");
    var batch: Batch = .{ .state = state };

    const count = switch (entries) {
        inline else => |items| items.len,
    };

    var scratch = std.heap.ArenaAllocator.init(state.arena.child_allocator);

    defer scratch.deinit();

    var buffer: [512]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());
    const temporary = fallback.allocator();

    const paths: []const []const u8 = switch (entries) {
        .rows => &.{},
        .paths => |names| resolve: {
            if (registered) break :resolve names;

            const absolute = try temporary.alloc([]const u8, names.len);

            for (names, absolute) |name, *path| {
                path.* = try std.fs.path.resolve(temporary, &.{ state.options.root_dir, name });
            }

            break :resolve absolute;
        },
    };

    const index = state.options.source_index.?;

    const input: std.meta.Child(generated.Input) = .{
        .batch = @ptrCast(&batch),
        .entries = count,
        .units = state.units.len,
        .rows = if (entries == .rows) entries.rows else null,
        .paths = paths,
        .index = &.{ .keys = index.keys, .buckets = @ptrCast(&index.buckets), .capacity = index.buckets.len },
    };

    const published = generated.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
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

pub fn reserveProjectSignatures(handle: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const batch = Batch.read(handle);
    batch.modules = try batch.state.allocator.alloc(project.Module, @intCast(count));
}

pub fn loadProjectSignature(handle: *anyopaque, row: u64) zx.Error!void {
    return Batch.read(handle).state.loadFrames(@intCast(row), .signature);
}

pub fn writeProjectSignature(handle: *anyopaque, slot: u64, row: u64) void {
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

pub fn finishProjectSignatures(handle: *anyopaque) void {
    const batch = Batch.read(handle);
    const state = batch.state;

    batch.result = .{
        .types = state.types.view(),
        .nominal_types = state.nominal_origins.items.view(),
        .native_modules = state.native_modules.view(),
        .functions = state.functions.view(),
        .store_initializers = state.store_initializers.items,
        .modules = batch.modules,
        .libraries = state.compiled_units.added,
    };
}
