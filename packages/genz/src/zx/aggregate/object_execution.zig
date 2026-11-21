const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const evaluation = @import("../expressions/evaluate.zig");
const layout = @import("layout.zig");
const object = @import("object.zig");
const operands = @import("operands.zig");
const Error = Lower.Error;
const Object = @FieldType(@FieldType(ir.ExpressionRow, "value"), "object");
const entry = @import("generated_lower_object_elements");

const Frame = struct {
    lowering: *Lower,
    temporary: std.mem.Allocator,
    id: ir.ExprId,
    source: Object,
    layout_only: bool,
    count: []u64,
    references: []node.ExpressionId,
    names: [][]const u8,
    values: []u32,
    body: std.ArrayList(node.Statement) = .empty,
    type_id: ir.TypeId = undefined,
    plan: layout.Plan = undefined,
    field_names: []const []const u8 = undefined,
    fields: []object.Field = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, temporary: std.mem.Allocator, id: ir.ExprId, source: Object, layout_only: bool) Error!node.ExpressionId {
    const length = source.evaluation.len;

    var frame: Frame = .{
        .lowering = self,
        .temporary = temporary,
        .id = id,
        .source = source,
        .layout_only = layout_only,
        .count = try temporary.alloc(u64, length),
        .references = try temporary.alloc(node.ExpressionId, length),
        .names = try temporary.alloc([]const u8, length),
        .values = try temporary.alloc(u32, length),
    };

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .batch = @ptrCast(&frame),
        .evaluation = @ptrCast(source.evaluation),
        .fields = source.fields.values[0..source.fields.len],
    };

    return evaluation.invoke(entry, &input);
}

pub fn reserveObjectOperand(handle: *const anyopaque, index: u64) Error!void {
    const frame = Frame.borrow(handle);

    frame.names[@intCast(index)] = try frame.lowering.fresh("operand");
}

pub fn publishObjectOperand(handle: *const anyopaque, index: u64, item: u32, value: u32) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const ordinal: usize = @intCast(index);
    frame.values[ordinal] = value;

    const reference = try self.builder.identifier(frame.names[ordinal]);
    frame.references[ordinal] = reference;
    frame.count[ordinal] = try self.cache.observe(self.allocator, @fromBackingInt(item), reference, self.cache_reads, null);
}

pub fn publishObjectOperands(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return operands.bind(frame.lowering, frame.temporary, &frame.body, frame.names, frame.values);
}

pub fn prepareObjectFields(handle: *const anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const source = frame.source;
    const updated = try @import("../object_update.zig").lower(self, frame.temporary, frame.id, &frame.body);
    frame.type_id = self.program.expression(frame.id).type_id;

    frame.plan = try layout.plan(self, frame.temporary, .{
        .id = frame.id,
        .type_id = frame.type_id,
        .layout_only = frame.layout_only,
        .updated = updated != null,
        .indices = source.fields.indices[0..source.fields.len],
    });

    if (updated) |result| return @backingInt(result);

    frame.field_names = self.program.typeOf(frame.type_id).object.names;
    frame.fields = try object.allocate(self, frame.temporary, source.fields.len);

    return null;
}

pub fn publishObjectField(handle: *const anyopaque, index: u64, item: u32, value: u32) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const ordinal: usize = @intCast(index);
    const field = frame.source.fields.indices[ordinal];
    const expression: node.ExpressionId = @fromBackingInt(value);

    const represented = switch (frame.plan.field(ordinal, field)) {
        .Direct => expression,
        .Borrowed => try @import("borrowed.zig").field(self, expression, frame.plan.projection.?.seed, frame.field_names[field]),
        .Pointer => try @import("../state_value/conversion.zig").convert(self, &frame.body, self.program.expression(@fromBackingInt(item)).type_id, try aggregate.bind(self, &frame.body, expression), .pointer),
    };

    frame.fields[ordinal] = object.operand(frame.field_names, field, represented);
}

pub fn finishObject(handle: *const anyopaque, updated: ?u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    try operands.retire(self, frame.temporary, &frame.body, .{
        .evaluation = frame.source.evaluation,
        .prior = frame.count,
        .references = frame.references,
    });

    const result = if (updated) |value| @as(node.ExpressionId, @fromBackingInt(value)) else lowered: {
        const object_type = if (frame.plan.projection) |projection| projection.layout else try self.layoutExpr(frame.type_id);

        break :lowered try object.lower(self, frame.temporary, .{
            .type_expr = object_type,
            .names = frame.field_names,
            .indices = frame.source.fields.indices,
            .fields = frame.fields,
        });
    };

    return @backingInt(try aggregate.finish(self, &frame.body, if (frame.plan.construct) try self.construct(frame.type_id, result) else result));
}
