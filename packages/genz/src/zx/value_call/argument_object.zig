const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const object_fields = @import("../aggregate/object.zig");
const operands = @import("../aggregate/operands.zig");
const evaluation = @import("../expressions/evaluate.zig");
const argument = @import("argument.zig");
const borrowed_argument = @import("borrowed_argument.zig");
const Error = Lower.Error;
const Object = @FieldType(@FieldType(ir.ExpressionRow, "value"), "object");

const Frame = struct {
    argument: *const argument.Frame,
    temporary: std.mem.Allocator,
    source: Object,
    type_id: ir.TypeId,
    counts: []u64,
    evaluated: []node.ExpressionId,
    field_names: []const []const u8,
    fields: []object_fields.Field = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn materializeBorrowedObject(handle: *const anyopaque) Error!u32 {
    const context = argument.Frame.borrow(handle);
    const self = context.lowering;
    const expression = self.program.expression(context.id);
    const source = expression.value.object;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: @TypeOf(self.cache).SnapshotBuffer = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const saved = try self.cache.snapshot(temporary, source.evaluation);

    defer self.cache.restore(self.allocator, source.evaluation, saved);

    var frame: Frame = .{
        .argument = context,
        .temporary = temporary,
        .source = source,
        .type_id = expression.type_id,
        .counts = try temporary.alloc(u64, source.evaluation.len),
        .evaluated = try temporary.alloc(node.ExpressionId, source.evaluation.len),
        .field_names = self.program.typeOf(expression.type_id).object.names,
    };

    const entry = @import("generated_materialize_borrowed_object");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(handle),
        .object = @ptrCast(&frame),
        .evaluation = @ptrCast(source.evaluation),
        .fields = source.fields.values[0..source.fields.len],
        .convert = self.state_active,
    };

    return @backingInt(try evaluation.invoke(entry, &input));
}

pub fn prepareBorrowedFields(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.fields = try object_fields.allocate(frame.argument.lowering, frame.temporary, frame.source.fields.len);
}

pub fn observeBorrowedOperand(handle: *anyopaque, index: u64, id: u32, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.argument.lowering;
    const ordinal: usize = @intCast(index);
    const bound = try aggregate.bind(self, frame.argument.body, @fromBackingInt(value));

    frame.evaluated[ordinal] = bound;
    frame.counts[ordinal] = self.cache_reads[id];

    return @backingInt(bound);
}

pub fn borrowedOperandCacheValue(handle: *const anyopaque, id: u32, value: u32) Error!u32 {
    const frame = argument.Frame.borrow(handle);
    const self = frame.lowering;
    const type_id = self.program.expression(@fromBackingInt(id)).type_id;

    return @backingInt(try @import("../state_value/conversion.zig").convert(self, frame.body, type_id, @fromBackingInt(value), .value));
}

pub fn cacheBorrowedOperand(handle: *const anyopaque, id: u32, value: u32) Error!void {
    const self = argument.Frame.borrow(handle).lowering;

    try self.cache.put(self.allocator, @fromBackingInt(id), @fromBackingInt(value));
}

pub fn publishBorrowedField(handle: *anyopaque, index: u64, value: u32) void {
    const frame = Frame.borrow(handle);
    const ordinal: usize = @intCast(index);
    frame.fields[ordinal] = object_fields.operand(frame.field_names, frame.source.fields.indices[ordinal], @fromBackingInt(value));
}

pub fn retireBorrowedOperands(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    try operands.retire(frame.argument.lowering, frame.temporary, frame.argument.body, .{
        .evaluation = frame.source.evaluation,
        .prior = frame.counts,
        .references = frame.evaluated,
    });
}

pub fn finishBorrowedObject(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.argument.lowering;
    const object_type = try @import("../types.zig").get(self, self.abi_layouts, frame.type_id);

    return @backingInt(try borrowed_argument.lower(self, frame.argument.body, .{ .object = .{
        .scratch = frame.temporary,
        .request = .{
            .type_expr = object_type,
            .names = frame.field_names,
            .indices = frame.source.fields.indices,
            .fields = frame.fields,
        },
    } }));
}
