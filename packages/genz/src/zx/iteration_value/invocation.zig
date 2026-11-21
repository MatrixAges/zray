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
    value_call: bool,
    previous: @FieldType(Context, "argument"),
    body: std.ArrayList(node.Statement) = .empty,
    cached: ?Cache.Binding = null,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn restore(self: *Frame) void {
        if (self.cached) |saved| saved.restore();

        self.context.argument = self.previous;
    }
};

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    var frame: Frame = .{ .context = self, .call_id = id, .row = row, .value_call = value_call, .previous = self.argument };

    defer frame.restore();

    if (!generated) {
        const value = try self.lowering.expr(row.value.call.argument);

        try openIterationCall(@ptrCast(&frame), @backingInt(value));

        return @fromBackingInt(try convertIterationCall(@ptrCast(&frame), try invokeIterationCall(@ptrCast(&frame))));
    }

    const entry = @import("generated_lower_iteration_call");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self.lowering),
        .call = @ptrCast(&frame),
        .operand = @backingInt(row.value.call.argument),
    };

    return evaluation.invoke(entry, &input);
}

pub fn openIterationCall(handle: *const anyopaque, value: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.context.lowering;
    const argument = frame.row.value.call.argument;
    const input_type: ir.TypeId = @fromBackingInt(self.program.expressions.types[@backingInt(argument)]);
    const bound = try aggregate.bind(self, &frame.body, @fromBackingInt(value));
    const input = try @import("borrow.zig").lower(frame.context, &frame.body, input_type, bound);

    frame.context.argument = .{ .id = argument, .value = input };
    frame.cached = try self.cache.bind(self.allocator, argument, input);
}

pub fn invokeIterationCall(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.context.lowering;

    return @backingInt(if (frame.value_call)
        try @import("../value_call/root.zig").invocation(self, frame.row.value.call)
    else
        try self.regular(frame.call_id));
}

pub fn convertIterationCall(handle: *const anyopaque, value: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.context.lowering;
    const bound = try aggregate.bind(self, &frame.body, @fromBackingInt(value));
    const converted = try @import("conversion.zig").convert(frame.context, frame.row.type_id, bound, false);

    return @backingInt(try aggregate.finish(self, &frame.body, converted));
}
