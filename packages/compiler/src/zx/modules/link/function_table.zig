const std = @import("std");
const ir = @import("zx").ir;
pub const valid = @import("../../ir/function_structure.zig").valid;
pub const range = @import("function_range.zig").plan;

pub fn join(allocator: std.mem.Allocator, base: ir.FunctionTable, delta: ir.FunctionTable) std.mem.Allocator.Error!ir.FunctionTable {
    if (delta.count() == 0) return base;
    if (base.count() == 0) return delta;

    var result: ir.FunctionTable = .{};

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        const first = @field(base, name);
        const second = @field(delta, name);
        const values = try allocator.alloc(std.meta.Elem(@TypeOf(first)), first.len + second.len);

        @memcpy(values[0..first.len], first);
        @memcpy(values[first.len..], second);
        @field(result, name) = values;
    }

    return result;
}

pub fn hasPrefix(table: ir.FunctionTable, prefix: ir.FunctionTable) bool {
    if (!valid(&table) or !valid(&prefix) or table.count() < prefix.count()) return false;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        if (!sameColumn(@field(table, name), @field(prefix, name))) return false;
    }

    return true;
}

pub fn appendTail(table: ir.FunctionTable, prefix: ir.FunctionTable, separate: ?*const ir.FunctionTable) ?ir.FunctionTable {
    if (!hasPrefix(table, prefix)) return null;

    if (separate) |suffix| {
        if (table.count() != prefix.count() or !valid(suffix)) return null;

        return suffix.*;
    }

    return table.suffix(prefix.count());
}

/// A table that extends another in place shares its columns, which settles the prefix without comparing rows.
fn sameColumn(values: anytype, expected: @TypeOf(values)) bool {
    if (values.ptr == expected.ptr) return true;

    for (values[0..expected.len], expected) |actual, previous| {
        if (!std.meta.eql(actual, previous)) return false;
    }

    return true;
}
