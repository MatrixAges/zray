const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const publication = @import("../construction/publication.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Error = Lower.Error;
const Object = @FieldType(@FieldType(ir.ExpressionRow, "value"), "object");
const entry = @import("generated_lower_object_elements");

const Frame = struct {
    lowering: *Lower,
    temporary: std.mem.Allocator,
    id: ir.ExprId,
    body: Sequence,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, temporary: std.mem.Allocator, id: ir.ExprId, source: Object, layout_only: bool) Error!node.ExpressionId {
    const type_id = self.program.expression(id).type_id;
    const field_indices = source.fields.indices[0..source.fields.len];

    var frame: Frame = .{
        .lowering = self,
        .temporary = temporary,
        .id = id,
        .body = self.builder.statementSequence(temporary),
    };

    defer frame.body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(&frame.body),
        .batch = @ptrCast(&frame),
        .id = @backingInt(id),
        .type_id = @backingInt(type_id),
        .layout_only = layout_only,
        .state_active = self.state_active,
        .selected = self.state_plan.selected[@backingInt(type_id)],
        .loop_states = if (self.loop_fields) |context| context.states else null,
        .borrowed = if (self.loop_fields) |context| context.borrowed else null,
        .projection_seed = if (self.loop_fields) |context| @backingInt(context.seed) else null,
        .projection_layout = if (self.loop_fields) |context| @backingInt(context.layout) else null,
        .evaluation = @ptrCast(source.evaluation),
        .field_indices = field_indices,
        .fields = source.fields.values[0..source.fields.len],
        .field_names = self.program.typeOf(type_id).object.names,
        .cache_reads = @ptrCast(&self.cache_reads),
    };

    return @fromBackingInt(entry.executeIn(temporary, &input) catch |err| return publication.failure(err));
}

pub fn publishObjectOperand(frame_handle: *anyopaque, item: u32, reference: u32) Error!u64 {
    const self = evaluation.borrow(frame_handle);

    return self.cache.observe(self.allocator, @fromBackingInt(item), @fromBackingInt(reference), self.cache_reads, null);
}

pub fn prepareObjectFields(handle: *anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const updated = try @import("../object_update.zig").lower(frame.lowering, frame.temporary, frame.id, &frame.body);

    return if (updated) |result| @backingInt(result) else null;
}

pub fn publishObjectField(handle: *anyopaque, item: u32, bound: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    return @backingInt(try @import("../state_value/conversion.zig").convert(self, &frame.body, self.program.expression(@fromBackingInt(item)).type_id, @fromBackingInt(bound), .pointer));
}

pub fn finishObject(frame_handle: *anyopaque, type_id: u32, value: u32) Error!u32 {
    return @backingInt(try evaluation.borrow(frame_handle).construct(@fromBackingInt(type_id), @fromBackingInt(value)));
}
