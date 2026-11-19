const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const structure = @import("function_structure.zig");
const generated = @import("parser_options").generated_parser;

pub fn count(table: ir.FunctionTable, verified: ir.FunctionTable) usize {
    const limit = @min(table.count(), verified.count());

    if (limit == 0) return 0;
    if (!structure.valid(&table) or !structure.valid(&verified)) return 0;
    if (sameColumns(&table, &verified)) return limit;
    if (comptime generated) return @import("verified_prefix/host.zig").scan(&table, &verified, limit, false);

    // Bound work by the first changed row even when a later column contains the mismatch.
    var first: usize = 0;

    while (first < limit) {
        const end = first + @min(limit - first, @max(first, 1));
        const matched = matching(&table, &verified, first, end, false);

        if (matched != end) return matched;

        first = end;
    }

    return limit;
}

/// Both tables have passed structural validation, including the lengths of their columns.
pub fn covers(table: *const ir.FunctionTable, prefix: *const ir.FunctionTable) bool {
    const limit = prefix.count();

    if (limit == 0 or sameColumns(table, prefix)) return true;
    if (comptime generated) return @import("verified_prefix/host.zig").scan(table, prefix, limit, true) == limit;

    return matching(table, prefix, 0, limit, true) == limit;
}

fn sameColumns(table: *const ir.FunctionTable, prefix: *const ir.FunctionTable) bool {
    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        if (@field(table, name).ptr != @field(prefix, name).ptr) return false;
    }

    return true;
}

fn matching(table: *const ir.FunctionTable, prefix: *const ir.FunctionTable, first: usize, end: usize, comptime all: bool) usize {
    var limit = end;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        const values = @field(table, name);
        const previous = @field(prefix, name);

        if (limit == first) return first;

        if (values.ptr != previous.ptr) {
            limit = first + compared(values[first..limit], previous[first..limit]);

            if (all and limit < end) return limit;
        }
    }

    return limit;
}

fn compared(left: anytype, right: @TypeOf(left)) usize {
    for (left, right, 0..) |a, b, index| if (!std.meta.eql(a, b)) return index;

    return left.len;
}
