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
    pub fn range(self: Columns, first: usize, end: usize) Columns {
        return .{
            .callees = self.callees[first..end],
            .variants = self.variants[first..end],
            .inline_names = if (self.inline_names) |names| names[first..end] else null,
        };
    }

    pub fn publish(self: Columns, rows: anytype) void {
        for (rows, self.callees, self.variants, 0..) |row, *callees, *variants, index| {
            callees.* = row.callees;
            variants.* = row.variants;

            if (self.inline_names) |names| names[index] = row.inline_names;
        }
    }
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

    const input: Input = .{
        .sources = @ptrCast(&sources),
        .index = &self.index,
        .first = 0,
        .end = files.len,
        .need_inline_names = output.inline_names != null,
    };

    const result = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| return failure(err);

    try valid(result.status);

    output.publish(result.rows);
}

pub fn valid(status: anytype) Error!void {
    return switch (status) {
        .Valid => {},
        .UnterminatedImport => error.UnterminatedImport,
        .UnsupportedFunctionReference => error.UnsupportedFunctionReference,
        .MissingFunctionFile => error.MissingFunctionFile,
    };
}

pub fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid partition scan input"),
    };
}
