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

pub fn lower(self: *Lower, temporary: std.mem.Allocator, id: ir.ExprId, source: Object, layout_only: bool) Error!node.ExpressionId {
    const type_id = self.program.expression(id).type_id;
    const field_indices = source.fields.indices[0..source.fields.len];
    var body = self.builder.statementSequence(temporary);

    defer body.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(&body),
        .expression_types = self.program.expressions.types,
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
        .cache_reads = self.cache_reads,
    };

    return @fromBackingInt(entry.executeIn(temporary, &input) catch |err| return publication.failure(err));
}

pub fn publishObjectOperand(frame_handle: *anyopaque, item: u32, reference: u32) Error!u64 {
    const self = evaluation.borrow(frame_handle);

    return self.cache.observe(self.allocator, @fromBackingInt(item), @fromBackingInt(reference), self.cache_reads, null);
}

pub fn prepareObjectFields(allocator: std.mem.Allocator, frame: *anyopaque, body: *anyopaque, id: u32) Error!?u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));
    const updated = try @import("../object_update.zig").lower(lowering, allocator, @fromBackingInt(id), sequence);

    return if (updated) |result| @backingInt(result) else null;
}
