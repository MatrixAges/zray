const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Current = @import("../restore.zig").Current;
const rule = @import("generated_semantic_restore_rollback");
const Input = std.meta.Child(rule.Input);
const type_fields = @typeInfo(ir.TypeStorage).@"struct".field_names;
const Self = @This();

type_counts: [type_fields.len]u64,
origins: usize,
functions: usize,
payload: zx.Arena.Checkpoint,
pub fn save(current: *const Current) Self {
    var counts: [type_fields.len]u64 = undefined;

    inline for (type_fields, &counts) |name, *count| {
        count.* = @field(current.types, name).items.len;
    }

    return .{
        .type_counts = counts,
        .origins = current.origins.items.ids.items.len,
        .functions = current.functions.count(),
        .payload = current.payloads.checkpoint(),
    };
}

pub fn rollback(self: *const Self, current: *const Current) void {
    const type_fields_view = memory.borrowColumnLengths(current.types);
    const origin_fields = memory.borrowColumnLengths(&current.origins.items);
    const changed = self.functions != current.functions.count();
    const function_fields = if (changed) memory.borrowColumnLengths(current.functions) else undefined;
    const types: memory.ColumnLengths = &type_fields_view;
    const origins: memory.ColumnLengths = &origin_fields;
    const functions: memory.ColumnLengths = if (changed) &function_fields else &.{};
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &.{
        .functions = if (changed) @ptrCast(&functions) else null,
        .function_count = self.functions,
        .types = @ptrCast(&types),
        .type_counts = &self.type_counts,
        .origins = @ptrCast(&origins),
        .origin_count = self.origins,
    }) catch unreachable;

    current.payloads.rewind(self.payload);
}
