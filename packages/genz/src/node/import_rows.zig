const std = @import("std");
const view = @import("view.zig");
const payloads = @import("import_payloads.zig");
const headers = @import("headers.zig");
const Counts = headers.Counts;

pub const Error = headers.Error;

pub fn append(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    return appendRows(allocator, target, source, true, false);
}

/// All slice payloads must outlive the target; the column descriptors themselves are copied.
pub fn appendBorrowed(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    return appendRows(allocator, target, source, false, false);
}

/// Text bytes must outlive the target; nested non-text slices receive owned storage.
pub fn appendBorrowingText(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    return appendRows(allocator, target, source, true, true);
}

pub fn check(target: anytype, source: anytype) Error!Counts(@TypeOf(target)) {
    @setEvalBranchQuota(100_000);

    const View = std.meta.Child(@TypeOf(source));
    const Payloads = @TypeOf(target.payloads);
    const names = @typeInfo(Payloads).@"struct".field_names;
    const Tag = std.meta.Child(@TypeOf(target.tags.items));
    const fields = @typeInfo(View).@"struct".field_names;

    comptime view.compatible(Tag, std.meta.Child(@FieldType(View, "tags")));

    var counts: Counts(@TypeOf(target)) = @splat(0);

    try headers.check(target.tags.items.len, source.tags, source.offsets, &counts, null);

    comptime var column_count: usize = 2;
    var valid = true;

    inline for (names, 0..) |name, index| {
        const Column = @FieldType(Payloads, name);

        column_count += comptime present(View, Column, name);
        valid = valid and validateColumn(Column, source, name, counts[index]);
    }

    if (comptime column_count != fields.len) @compileError("AST import has unknown columns");
    if (!valid) return error.InvalidAst;

    return counts;
}

fn appendRows(allocator: std.mem.Allocator, target: anytype, source: anytype, comptime copy_payloads: bool, comptime borrow_text: bool) Error!void {
    const counts = try check(target, source);

    return payloads.append(allocator, target, source, &counts, .dense, copy_payloads, borrow_text);
}

fn present(comptime View: type, comptime Column: type, comptime prefix: []const u8) usize {
    if (!@hasField(Column, "fields")) return @intFromBool(@hasField(View, prefix));

    var count: usize = 0;
    const Fields = @FieldType(Column, "fields");

    for (@typeInfo(Fields).@"struct".field_names) |name| {
        count += present(View, @FieldType(Fields, name), prefix ++ "_" ++ name);
    }

    return count;
}

inline fn validateColumn(comptime Column: type, source: anytype, comptime prefix: []const u8, count: usize) bool {
    const View = std.meta.Child(@TypeOf(source));

    if (@hasField(Column, "fields")) {
        const Fields = @FieldType(Column, "fields");
        var valid = true;

        inline for (@typeInfo(Fields).@"struct".field_names) |name| {
            valid = valid and validateColumn(@FieldType(Fields, name), source, prefix ++ "_" ++ name, count);
        }

        return valid;
    }

    const Value = std.meta.Child(@FieldType(@FieldType(Column, "values"), "items"));

    if (Value == void) return true;

    if (@hasField(View, prefix)) {
        comptime view.compatible(Value, std.meta.Child(@FieldType(View, prefix)));

        return @field(source, prefix).len == count;
    }

    return count == 0;
}
