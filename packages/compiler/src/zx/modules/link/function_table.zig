const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const structure = @import("../../ir/function_structure.zig");
const coverage = @import("../../ir/verified_prefix.zig");
const generated = @import("parser_options").generated_parser;
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

pub const Shared = struct {
    functions: *const ir.FunctionStorage,
    natives: *const ir.NativeModuleStorage,
    source_natives: ir.NativeModuleTable,
    type_count: usize,
    base_types: ?usize,
};

pub const Extension = struct { tail: ir.FunctionTable, total: u64, types: usize };

pub fn hasPrefix(table: ir.FunctionTable, prefix: ir.FunctionTable) bool {
    return appendTail(table, prefix, null) != null;
}

pub fn appendTail(table: ir.FunctionTable, prefix: ir.FunctionTable, separate: ?*const ir.FunctionTable) ?ir.FunctionTable {
    return (extend(table, prefix, separate, null) catch return null).tail;
}

pub fn extend(table: ir.FunctionTable, prefix: ir.FunctionTable, separate: ?*const ir.FunctionTable, shared: ?Shared) error{ InvalidModule, OutOfMemory }!Extension {
    if (comptime !generated) {
        if (shared) |storage| {
            if (storage.base_types == null and !sameView(prefix, storage.functions.view())) return error.InvalidModule;
            if (prefix.count() > storage.functions.count() or !sameView(storage.source_natives, storage.natives.view())) return error.InvalidModule;
        }

        if (table.count() < prefix.count() or !valid(&prefix)) return error.InvalidModule;
        if (!structure.validSuffix(&table, prefix.count()) or !coverage.covers(&table, &prefix)) return error.InvalidModule;

        const tail = if (separate) |suffix| blk: {
            if (table.count() != prefix.count() or !valid(suffix)) return error.InvalidModule;

            break :blk suffix.*;
        } else table.suffix(prefix.count());

        const total = @as(u64, prefix.count()) + @as(u64, tail.count());

        if (shared != null and total > std.math.maxInt(usize)) return error.OutOfMemory;

        return .{
            .tail = tail,
            .total = total,
            .types = if (shared) |storage| storage.base_types orelse storage.type_count else 0,
        };
    }

    const rule = @import("generated_source_link_tail");
    const Input = std.meta.Child(rule.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const view = @import("../../ir/canonical/functions/input.zig").view;
    const functions = view(Functions, table);
    const base = view(Functions, prefix);
    const suffix = if (separate) |part| view(Functions, part.*) else undefined;
    var prefix_storage: @import("../../ir/verified_prefix/host.zig").Storage = .{};
    const compare = prefix.count() != 0 and !coverage.sameColumns(&table, &prefix);
    const borrowed = if (compare) prefix_storage.bind(&table, &prefix, prefix.count(), true) else undefined;

    const input: Input = .{
        .functions = &functions,
        .base = &base,
        .suffix = if (separate != null) &suffix else null,
        .maximum_count = std.math.maxInt(u32),
        .coverage = if (compare) zx.columns.pointer(std.meta.Child(@FieldType(Input, "coverage")), &borrowed) else null,
        .shared = if (shared) |storage| &.{
            .same_functions = storage.base_types != null or sameView(prefix, storage.functions.view()),
            .same_natives = sameView(storage.source_natives, storage.natives.view()),
            .functions = storage.functions.count(),
            .types = storage.type_count,
            .base_types = storage.base_types,
            .size_limit = std.math.maxInt(usize),
        } else null,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const selected = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidModule;
    const result = selected orelse return error.InvalidModule;

    return .{
        .tail = switch (result.tail) {
            .Separate => separate.?.*,
            .Embedded => table.suffix(prefix.count()),
            .Exhausted => return error.OutOfMemory,
        },
        .total = result.total,
        .types = @intCast(result.types),
    };
}

fn sameView(left: anytype, right: @TypeOf(left)) bool {
    inline for (@typeInfo(@TypeOf(left)).@"struct".field_names) |name| {
        const a = @field(left, name);
        const b = @field(right, name);

        if (a.len != b.len or (a.len != 0 and a.ptr != b.ptr)) return false;
    }

    return true;
}
