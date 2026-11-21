const std = @import("std");
const view = @import("view.zig");
const payloads = @import("import_payloads.zig");
const headers = @import("headers.zig");
const Counts = headers.Counts;
const Error = headers.Error;

/// Headers select rows from shared payload columns; unselected payloads are not imported.
pub fn check(target: anytype, source: anytype) Error!Counts(@TypeOf(target)) {
    @setEvalBranchQuota(100_000);

    const Tag = std.meta.Child(@TypeOf(target.tags.items));
    const View = std.meta.Child(@TypeOf(source));
    const names = @typeInfo(@TypeOf(target.payloads)).@"struct".field_names;

    comptime view.compatible(Tag, std.meta.Child(@FieldType(View, "tags")));

    try headers.capacity(target.tags.items.len, source.tags.len, source.offsets.len);

    comptime var columns: usize = 2;

    inline for (names) |name| columns += comptime schema(View, @TypeOf(@field(target.payloads, name)), name);

    if (comptime columns != @typeInfo(View).@"struct".field_names.len) @compileError("AST selection has unknown columns");

    var counts: Counts(@TypeOf(target)) = @splat(0);
    var limits: [names.len]u64 = undefined;

    inline for (names, &limits) |name, *limit| {
        limit.* = available(@TypeOf(@field(target.payloads, name)), source, name);
    }

    try headers.check(source.tags, source.offsets, &counts, &limits);

    return counts;
}

pub fn append(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    return appendRows(allocator, target, source, false);
}

/// Text must outlive every imported row; other nested payloads receive owned storage.
pub fn appendBorrowingText(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    return appendRows(allocator, target, source, true);
}

fn appendRows(allocator: std.mem.Allocator, target: anytype, source: anytype, comptime borrow_text: bool) Error!void {
    const counts = try check(target, source);

    return payloads.append(allocator, target, source, &counts, .selected, true, borrow_text);
}

fn schema(comptime View: type, comptime Column: type, comptime prefix: []const u8) usize {
    if (@hasField(Column, "fields")) {
        comptime var count: usize = 0;

        inline for (@typeInfo(@FieldType(Column, "fields")).@"struct".field_names) |name| {
            count += schema(View, @FieldType(@FieldType(Column, "fields"), name), prefix ++ "_" ++ name);
        }

        return count;
    }

    if (!@hasField(View, prefix)) return 0;

    view.compatible(std.meta.Child(@FieldType(@FieldType(Column, "values"), "items")), std.meta.Child(@FieldType(View, prefix)));

    return 1;
}

fn available(comptime Column: type, source: anytype, comptime prefix: []const u8) u64 {
    const View = std.meta.Child(@TypeOf(source));

    if (@hasField(Column, "fields")) {
        const Fields = @FieldType(Column, "fields");
        var count: u64 = std.math.maxInt(u64);

        inline for (@typeInfo(Fields).@"struct".field_names) |name| {
            count = @min(count, available(@FieldType(Fields, name), source, prefix ++ "_" ++ name));
        }

        return count;
    }

    if (std.meta.Child(@FieldType(@FieldType(Column, "values"), "items")) == void) return std.math.maxInt(u64);

    return if (@hasField(View, prefix)) @field(source, prefix).len else 0;
}
