const std = @import("std");
const owner = @import("../../../project.zig");
const Project = owner.Project;
const project = owner.signature_project;
const Value = @FieldType(project.Result, "value");

pub fn run(state: *Project, entries: project.Entries, registered: bool) std.mem.Allocator.Error!Value {
    const generated = @import("generated_project_signatures_batch");

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
        .entries = count,
        .units = state.units.len,
        .rows = if (entries == .rows) entries.rows else null,
        .paths = paths,
        .index = &.{ .keys = index.keys, .buckets = @ptrCast(&index.buckets), .capacity = index.buckets.len },
    };

    const modules = try state.allocator.alloc(project.Module, count);

    const selected = generated.executeIn(temporary, &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };

    for (selected.items, modules[0..selected.items.len]) |row, *output| {
        state.loadFrames(@intCast(row), .signature) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            var issue = state.reporter.diagnostic.?;

            issue.source_index = state.current_source;

            return .{ .diagnostic = issue };
        };

        const unit = &state.units[@intCast(row)];

        output.* = .{
            .path = unit.path,
            .source_row = @intCast(row),
            .signature = unit.signature.?,
            .type_imports = unit.signature_aliases,
            .function_imports = unit.signature_imports,
            .reexport_functions = unit.signature_reexports,
            .constant_imports = unit.signature_constant_imports,
        };
    }

    if (!selected.complete) return .{ .diagnostic = project.missing_entry };

    return .{ .data = .{
        .types = state.types.view(),
        .nominal_types = state.nominal_origins.items.view(),
        .native_modules = state.native_modules.view(),
        .functions = state.functions.view(),
        .store_initializers = state.store_initializers.items,
        .modules = modules,
        .libraries = state.compiled_units.added,
    } };
}
