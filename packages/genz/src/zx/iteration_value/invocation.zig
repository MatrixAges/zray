const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Cache = @import("../expression_map.zig").Map(ir.ExprId);
const generated = @import("genz_options").generated_analysis;

const Frame = struct {
    context: *Context,
    call_id: ir.ExprId,
    row: ir.ExpressionRow,
    previous: @FieldType(Context, "argument"),
    body: Context.Statements,
    cached: ?Cache.Binding = null,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
    fn restore(self: *Frame) void {
        if (self.cached) |saved| saved.restore();

        self.context.argument = self.previous;
    }
};

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    var frame: Frame = .{
        .context = self,
        .call_id = id,
        .row = row,
        .previous = self.argument,
        .body = if (generated) self.lowering.builder.statementSequence(self.lowering.workspace) else .empty,
    };

    defer frame.restore();
    defer if (generated) frame.body.deinit();

    if (!generated) {
        const value = try self.lowering.expr(row.value.call.argument);

        try openIterationCall(@ptrCast(&frame), @backingInt(value));

        const invocation = if (value_call)
            try invokeIterationValue(@ptrCast(&frame))
        else
            try invokeIterationRegular(@ptrCast(&frame));

        return @fromBackingInt(try convertResult(&frame, invocation));
    }

    const entry = @import("generated_lower_iteration_call");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self.lowering),
        .call = @ptrCast(&frame),
        .operand = @backingInt(row.value.call.argument),
        .value_call = value_call,
    };

    return evaluation.invoke(entry, &input);
}

pub fn openIterationCall(handle: *anyopaque, value: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.context.lowering;
    const argument = frame.row.value.call.argument;
    const input_type: ir.TypeId = @fromBackingInt(self.program.expressions.types[@backingInt(argument)]);
    const bound = try aggregate.bind(self, &frame.body, @fromBackingInt(value));
    const input = try @import("borrow.zig").lower(frame.context, &frame.body, input_type, bound);

    frame.context.argument = .{ .id = argument, .value = input };
    frame.cached = try self.cache.bind(self.allocator, argument, input);
}

pub fn invokeIterationValue(handle: *anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../value_call/root.zig").invocation(frame.context.lowering, frame.row.value.call));
}

pub fn invokeIterationRegular(handle: *anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.context.lowering.regular(frame.call_id));
}

pub fn convertIterationCall(handle: *anyopaque, value: u32) Lower.Error!u32 {
    return convertResult(Frame.borrow(handle), value);
}

fn convertResult(frame: *Frame, value: u32) Lower.Error!u32 {
    const self = frame.context.lowering;
    const bound = try aggregate.bind(self, &frame.body, @fromBackingInt(value));
    const converted = try @import("conversion.zig").convert(frame.context, frame.row.type_id, bound, false);

    return @backingInt(try aggregate.finish(self, &frame.body, converted));
}
