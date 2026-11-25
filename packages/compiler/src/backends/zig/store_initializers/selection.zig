const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const memory = zx.memory;
const selection = @import("generated_store_initializer_selection");
const strategy = @import("generated_store_selection_strategy");
const Result = @typeInfo(@typeInfo(@TypeOf(selection.executeValue)).@"fn".return_type.?).error_union.payload;
const Entry = frontend.project.compiled.StoreInitializer;

pub fn plan(scratch: std.mem.Allocator, application: *const zx.ir.Program, initializers: []const Entry, owned: usize, borrowed: usize, files: usize) (std.mem.Allocator.Error || error{InvalidInitializer})!Result {
    const paths = application.stores.paths;
    const counts: std.meta.Child(strategy.Input) = .{ .paths = paths.len, .initializers = initializers.len };
    const size = zx.columns.invoke(strategy.executeValue, scratch, &counts) catch unreachable;
    var buckets = try frontend.project.source_index.Map.bucketsFor(scratch, @intCast(size.indexed));
    var marks = try scratch.alloc(u8, @intCast(size.marks));

    @memset(marks, 0);

    const path_keys = memory.borrowTextSlice(paths);
    const keys = memory.borrowTextColumn("identity", initializers);
    const functions = memory.borrowReadColumn(zx.ir.FunctionId, "function", initializers);

    const input: std.meta.Child(selection.Input) = .{
        .sources = &.{ .owned = owned, .borrowed = borrowed, .files = files, .maximum = std.math.maxInt(usize) },
        .indexed = size.indexed,
        .candidates = &.{ .keys = @ptrCast(&keys), .count = initializers.len, .functions = @ptrCast(&functions), .function_count = application.functions.count(), .native_modules = application.functions.native_modules },
        .search = &.{
            .index = &.{ .keys = @ptrCast(if (size.mode == .Candidates) &keys else &path_keys), .buckets = @ptrCast(&buckets), .capacity = buckets.len },
            .paths = paths,
            .mode = size.mode,
            .marks = @ptrCast(&marks),
        },
    };

    const result = zx.columns.invoke(selection.executeValue, scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidInitializer,
    };

    return switch (result.status) {
        .Invalid => error.InvalidInitializer,
        .Overflow => error.OutOfMemory,
        .Ready => result,
    };
}
