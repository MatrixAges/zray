const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Current = @import("../restore.zig").Current;
const rule = @import("generated_semantic_restore_rollback");
const capture = @import("generated_semantic_restore_snapshot");
const Counts = std.meta.Child(capture.Output);
const type_fields = @typeInfo(ir.TypeStorage).@"struct".field_names;
const Self = @This();

type_counts: [type_fields.len]u64,
origins: usize,
functions: usize,
payload: zx.Arena.Checkpoint,
pub fn save(current: *const Current) Self {
    var type_counts: [type_fields.len]u64 = undefined;
    const target: []u64 = &type_counts;
    const type_slots = memory.borrowColumnLengths(current.types);
    const origin_slots = memory.borrowColumnLengths(&current.origins.items);
    const function_slots = memory.borrowColumnLengths(current.functions);
    const types: memory.ColumnLengths = &type_slots;
    const origins: memory.ColumnLengths = &origin_slots;
    const functions: memory.ColumnLengths = &function_slots;
    var storage: [@sizeOf(Counts)]u8 align(@alignOf(Counts)) = undefined;
    var workspace = std.heap.FixedBufferAllocator.init(&storage);

    const saved = capture.executeIn(workspace.allocator(), &.{
        .types = @ptrCast(&types),
        .origins = @ptrCast(&origins),
        .functions = @ptrCast(&functions),
        .type_counts = @ptrCast(&target),
    }) catch unreachable;

    return .{
        .type_counts = type_counts,
        .origins = @intCast(saved.origin_count),
        .functions = @intCast(saved.function_count),
        .payload = current.payloads.checkpoint(),
    };
}

pub fn rollback(self: *const Self, current: *const Current) void {
    const type_fields_view = memory.borrowColumnLengths(current.types);
    const origin_fields = memory.borrowColumnLengths(&current.origins.items);
    const function_fields = memory.borrowColumnLengths(current.functions);
    const types: memory.ColumnLengths = &type_fields_view;
    const origins: memory.ColumnLengths = &origin_fields;
    const functions: memory.ColumnLengths = &function_fields;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &.{
        .functions = @ptrCast(&functions),
        .function_count = self.functions,
        .types = @ptrCast(&types),
        .type_counts = &self.type_counts,
        .origins = @ptrCast(&origins),
        .origin_count = self.origins,
    }) catch unreachable;

    current.payloads.rewind(self.payload);
}
