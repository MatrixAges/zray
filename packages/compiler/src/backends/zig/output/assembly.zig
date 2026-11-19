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
    const paths = memory.borrowWriteColumn([]const u8, "path", files);
    const sources = memory.borrowWriteColumn([]const u8, "source", files);
    const names = memory.borrowWriteColumn([]const u8, "name", modules);
    const module_files = memory.borrowWriteColumn([]const u8, "file", modules);
    const support_paths = memory.borrowTextColumn("path", groups.support);
    const support_bodies = memory.borrowTextColumn("source", groups.support);
    const public_paths = memory.borrowNestedColumn([]const u8, &.{ "file", "name" }, bundle.public_modules);
    const public_bodies = memory.borrowNestedColumn([]const u8, &.{ "file", "source" }, bundle.public_modules);
    const public_names = memory.borrowTextColumn("name", bundle.public_modules);
    const planned = sectionFields(std.meta.Child(@FieldType(Input, "sections")), sections);

    const input: Input = .{
        .partitioned = partitioned,
        .sections = &planned,
        .public = &.{
            .paths = @ptrCast(&public_paths),
            .bodies = @ptrCast(&public_bodies),
            .count = counts.public_count,
            .names = @ptrCast(&public_names),
        },
        .support = &.{ .paths = @ptrCast(&support_paths), .bodies = @ptrCast(&support_bodies), .count = counts.support_count },
        .files = &.{ .paths = @ptrCast(&paths), .bodies = @ptrCast(&sources) },
        .modules = &.{ .names = @ptrCast(&names), .files = @ptrCast(&module_files) },
        .types = bundle.types,
        .signatures = bundle.signatures orelse "",
    };

    try zx.columns.invoke(entry.executeValue, allocator, &input);

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

pub fn mark(files: []const File, names: [][]const u8, hashes: []u64) void {
    if (comptime !available) {
        for (files, names, hashes) |file, *path, *hash| {
            path.* = file.path;
            hash.* = zx.bytes.hash(0, file.source);
        }

        return;
    }

    const entry = @import("generated_output_mark");
    const paths = memory.borrowTextColumn("path", files);
    const bodies = memory.borrowTextColumn("source", files);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(entry.Input) = .{
        .paths = @ptrCast(&paths),
        .bodies = @ptrCast(&bodies),
        .names = @ptrCast(&names),
        .hashes = @ptrCast(&hashes),
        .count = files.len,
    };

    zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}
