const std = @import("std");
const zx = @import("zx");
const generation = @import("../partition.zig");
const Scanning = @import("workers.zig");
const parallel = @import("../output/parallel.zig");
pub const File = generation.placement.File;
const available = generation.groups.available and generation.layout.available;
const native = if (available) @import("output_execution_abi").layouts.@"zig:output_host" else struct {};

/// Groups public entry closures into separately compiled units.
pub fn plan(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, temporary: std.mem.Allocator, functions: []const File, columns: generation.layout.FunctionFiles, top: []const File, count: u32) ![]File {
    if (comptime !available) return @import("build_seed.zig").plan(io, allocator, workspace, functions, top, count);

    const scanner = try generation.Scanning.init(temporary, columns.paths);
    const arenas = try parallel.Arenas.init(io, temporary, functions.len);

    defer arenas.deinit();

    const workers: BodyScan = .{ .arenas = arenas, .files = functions, .scanner = &scanner };
    const entry = @import("generated_bootstrap_partition");
    const Input = std.meta.Child(entry.Input);
    const Support = std.meta.Child(@FieldType(Input, "support"));
    const index = zx.columns.borrow(std.meta.Child(@FieldType(Support, "index")), &scanner.index);
    const bodies = zx.memory.borrowTextColumn("source", functions);
    const sources = zx.memory.borrowTextColumn("source", top);

    const input: Input = .{
        .workers = @ptrCast(&workers),
        .files = &.{ .paths = columns.paths, .bodies = @ptrCast(&bodies) },
        .support = &.{
            .sources = @ptrCast(&sources),
            .index = &index,
            .first = 0,
            .end = top.len,
            .need_inline_names = false,
        },
        .paths = columns.paths,
        .sizes = columns.sizes,
        .count = count,
    };

    const result = entry.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return err,
    };

    try generation.Scanning.valid(result.status);

    const layout = result.layout.?;
    const publication = try generation.placement.materialize(temporary, layout.placement, result.files.?);

    if (publication.jobs.len != 0) try parallel.eachRender(arenas, .{
        .owner = allocator,
        .workspace = workspace,
        .columns = columns,
        .roots = zx.columns.slice(@FieldType(parallel.Rendering, "roots"), layout.roots),
        .jobs = publication.jobs,
        .files = publication.files,
    });

    return publication.files;
}

const BodyScan = struct {
    arenas: parallel.Arenas,
    files: []const File,
    scanner: *const generation.Scanning,
};

pub fn scanPartitionBodies(allocator: std.mem.Allocator, capability: *const anyopaque) generation.Scanning.Error!*const native.PartitionBodyColumns {
    const workers: *const BodyScan = @ptrCast(@alignCast(capability));
    const scanned = Scanning.run(allocator, workers.arenas, workers.files, workers.scanner) catch |err| return @errorCast(err);
    const result = try allocator.create(native.PartitionBodyColumns);

    result.* = .{ .callees = scanned.callees, .variants = scanned.variants, .inline_names = scanned.inline_names };

    return result;
}
