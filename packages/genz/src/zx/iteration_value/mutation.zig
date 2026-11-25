const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Operand = @import("operand.zig");
const emission = @import("mutation_emission.zig");
const entry = @import("generated_execute_iteration_mutation");
const Api = evaluation.Api;
const Slot = Api.IterationOperandSlot;
const slot_count = @typeInfo(Slot).@"enum".field_names.len;

const Frame = struct {
    context: *Context,
    operands: [slot_count]Operand = @splat(.empty),
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(context: *Context, id: zx.ir.ExprId) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(entry.Input);
    const program: *const zx.ir.Program = &context.lowering.program;
    const expressions = zx.columns.borrow(std.meta.Child(@FieldType(Input, "expressions")), &program.expressions);
    var frame: Frame = .{ .context = context };

    return evaluation.invoke(entry, &.{
        .frame = @ptrCast(&frame),
        .context = @ptrCast(context),
        .expressions = &expressions,
        .id = @backingInt(id),
    });
}

pub fn bindIterationMutationOperand(handle: *anyopaque, slot: Slot, id: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.operands[@intFromEnum(slot)] = try Operand.lower(frame.context.lowering, @fromBackingInt(id));
}

pub fn publishIterationMutation(handle: *anyopaque, mode: Api.IterationMutationMode, list_layout: u32, result_layout: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try emission.lower(frame.context, .{
        .mode = zx.columns.view(emission.Mode, mode),
        .target = frame.operands[@intFromEnum(Slot.Target)],
        .index = frame.operands[@intFromEnum(Slot.Index)],
        .value = frame.operands[@intFromEnum(Slot.Value)],
        .list_layout = @fromBackingInt(list_layout),
        .result_layout = @fromBackingInt(result_layout),
    }));
}
