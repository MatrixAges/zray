const std = @import("std");
const ir = @import("zx").ir;
const structure = @import("../../ir/function_structure.zig");
pub const valid = structure.valid;
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
    return appendTail(table, prefix, null) != null;
}

pub fn appendTail(table: ir.FunctionTable, prefix: ir.FunctionTable, separate: ?*const ir.FunctionTable) ?ir.FunctionTable {
    const covers = @import("../../ir/verified_prefix.zig").covers;

    if (comptime !@import("parser_options").generated_parser) {
        if (table.count() < prefix.count() or !valid(&prefix)) return null;
        if (!structure.validSuffix(&table, prefix.count()) or !covers(&table, &prefix)) return null;

        if (separate) |suffix| {
            if (table.count() != prefix.count() or !valid(suffix)) return null;

            return suffix.*;
        }

        return table.suffix(prefix.count());
    }

    const rule = @import("generated_source_link_tail");
    const Input = std.meta.Child(rule.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const view = @import("../../ir/canonical/functions/input.zig").view;
    const functions = view(Functions, table);
    const base = view(Functions, prefix);
    const suffix = if (separate) |part| view(Functions, part.*) else undefined;

    const input: Input = .{
        .functions = &functions,
        .base = &base,
        .suffix = if (separate != null) &suffix else null,
        .maximum_count = std.math.maxInt(u32),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const selected = @import("zx").columns.invoke(rule.executeValue, empty.allocator(), &input) catch return null;

    if (selected == .Invalid or !covers(&table, &prefix)) return null;

    return if (selected == .Separate) separate.?.* else table.suffix(prefix.count());
}
