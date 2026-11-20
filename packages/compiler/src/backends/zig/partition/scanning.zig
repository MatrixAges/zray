const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const path_index = @import("../path_index.zig");
pub const batch_size = if (generated) @import("generated_partition_scan_constants").@"zx.constants".batch_size else 8;
const Index = if (generated) path_index.Index else zx.bytes.Map(u32);
const Self = @This();
pub const References = struct { callees: []const u32, variants: []const []const u8 };
pub const Error = std.mem.Allocator.Error || error{ UnterminatedImport, UnsupportedFunctionReference, MissingFunctionFile };

pub const Columns = struct {
    callees: [][]const u32,
    variants: [][]const []const u8,
    inline_names: ?[][]const []const u8 = null,
};

index: Index,
pub fn init(allocator: std.mem.Allocator, paths: []const []const u8) Error!Self {
    if (comptime !generated) {
        var index: Index = .empty;

        try index.ensureTotalCapacity(allocator, @intCast(paths.len));
        for (paths, 0..) |path, position| index.putAssumeCapacity(path, @intCast(position));

        return .{ .index = index };
    }

    return .{ .index = try path_index.build(allocator, paths) };
}

pub fn scan(self: *const Self, allocator: std.mem.Allocator, files: anytype, output: Columns) Error!void {
    if (comptime !generated) {
        const seed = @import("scanning_seed.zig");

        for (files, output.callees, output.variants, 0..) |file, *callees, *variants, row| {
            const reference = try seed.references(allocator, file.source, &self.index);

            callees.* = reference.callees;
            variants.* = reference.variants;

            if (output.inline_names) |names| names[row] = try seed.inlineNames(allocator, file.source);
        }

        return;
    }

    const entry = @import("generated_partition_scan_batch");
    const Input = std.meta.Child(entry.Input);
    const sources = zx.memory.borrowTextColumn("source", files);
    const variants = zx.memory.borrowNestedWriteColumn([]const []const u8, &.{}, output.variants);
    const inline_names = if (output.inline_names) |names| zx.memory.borrowNestedWriteColumn([]const []const u8, &.{}, names) else null;

    const input: Input = .{
        .sources = @ptrCast(&sources),
        .index = &self.index,
        .count = files.len,
        .callees = @ptrCast(&output.callees),
        .variants = @ptrCast(&variants),
        .inline_names = if (inline_names != null) @ptrCast(&inline_names.?) else null,
    };

    return valid(zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| return failure(err));
}

fn valid(status: anytype) Error!void {
    return switch (status) {
        .Valid => {},
        .UnterminatedImport => error.UnterminatedImport,
        .UnsupportedFunctionReference => error.UnsupportedFunctionReference,
        .MissingFunctionFile => error.MissingFunctionFile,
    };
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid partition scan input"),
    };
}
