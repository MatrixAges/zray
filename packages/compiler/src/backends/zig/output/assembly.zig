const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const available = @import("../output.zig").available;
const File = @import("../partition/placement.zig").File;
const Module = @import("../partition.zig").Module;
const Bundle = @import("../library.zig").Bundle;
const Groups = @import("inventory.zig").Groups;
const seed = @import("assembly_seed.zig");
const settings = if (available) @import("generated_output_assembly_constants").@"zx.constants" else seed;
pub const hash_batch = settings.hash_batch;
pub const Counts = struct { public_count: usize, support_count: usize, function_count: usize, partitioned: bool };

pub const Sections = struct {
    adapters: usize,
    support: usize,
    public_files: usize,
    signatures: usize,
    originals: usize,
    original_root: usize,
    root: usize,
    length: usize,
};

pub const Assembly = struct {
    files: []File,
    modules: []Module,
    sections: Sections,
};

pub fn prepare(allocator: std.mem.Allocator, bundle: *const Bundle, groups: Groups, partitioned: bool) !Assembly {
    const counts: Counts = .{ .public_count = bundle.public_modules.len, .support_count = groups.support.len, .function_count = groups.functions.len, .partitioned = partitioned };
    const sections = positions(counts);
    const files = try allocator.alloc(File, sections.length);
    const modules = try allocator.alloc(Module, counts.public_count);
    const assembly: Assembly = .{ .files = files, .modules = modules, .sections = sections };

    if (comptime !available) {
        try seed.fill(allocator, bundle, groups.support, assembly, partitioned);

        return assembly;
    }

    const entry = @import("generated_output_assembly");
    const Input = std.meta.Child(entry.Input);
    const support = memory.borrowReadFields(.{ .paths = "path", .bodies = "source" }, groups.support);
    const public_paths = memory.borrowNestedColumn([]const u8, &.{ "file", "name" }, bundle.public_modules);
    const public_bodies = memory.borrowNestedColumn([]const u8, &.{ "file", "source" }, bundle.public_modules);
    const public_names = memory.borrowTextColumn("name", bundle.public_modules);

    const input: Input = .{
        .partitioned = partitioned,
        .public = &.{
            .paths = @ptrCast(&public_paths),
            .bodies = @ptrCast(&public_bodies),
            .count = counts.public_count,
            .names = @ptrCast(&public_names),
        },
        .support = &support.bind(std.meta.Child(@FieldType(Input, "support"))),
        .types = bundle.types,
        .signatures = bundle.signatures orelse "",
    };

    const output = try zx.columns.invoke(entry.executeValue, allocator, &input);

    files[0] = .{ .path = output.types_file.path, .source = output.types_file.source };
    files[sections.root].path = output.root_path;

    for (output.adapters, files[sections.adapters..][0..output.adapters.len]) |path, *slot| {
        slot.path = path;
    }

    for (output.public_files, files[sections.public_files..][0..output.public_files.len]) |item, *slot| {
        slot.* = .{ .path = item.path, .source = item.source };
    }

    for (output.modules, modules) |item, *slot| {
        slot.* = .{ .name = item.name, .file = item.file };
    }

    for (output.support, files[sections.support..][0..output.support.len]) |item, *slot| {
        slot.* = .{ .path = item.path, .source = item.source };
    }

    if (partitioned) {
        const signatures_file = output.signatures_file.?;

        files[sections.signatures] = .{ .path = signatures_file.path, .source = signatures_file.source };
        files[sections.original_root].path = output.original_root_path.?;
    }

    return assembly;
}

fn positions(counts: Counts) Sections {
    if (comptime !available) return seed.positions(counts);

    const entry = @import("generated_output_sections");
    const Input = if (@typeInfo(entry.Input) == .pointer) std.meta.Child(entry.Input) else entry.Input;

    const input: Input = .{
        .public_count = counts.public_count,
        .support_count = counts.support_count,
        .function_count = counts.function_count,
        .partitioned = counts.partitioned,
    };

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const placed = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;

    return sectionFields(Sections, placed);
}

fn sectionFields(comptime Target: type, source: anytype) Target {
    var result: Target = undefined;

    inline for (@typeInfo(Target).@"struct".field_names) |name| @field(result, name) = @intCast(@field(source, name));

    return result;
}
