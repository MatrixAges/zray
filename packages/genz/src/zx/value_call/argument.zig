const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const conversion = @import("../state_value/conversion.zig");
const evaluation = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;
const Error = Lower.Error;

pub const Frame = struct {
    lowering: *Lower,
    body: *Sequence,
    id: ir.ExprId,
    pub fn borrow(handle: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn borrow(self: *Lower, body: anytype, id: ir.ExprId) Error!node.ExpressionId {
    if (comptime !generated) return @import("argument_seed.zig").borrow(self, body, id);

    const entry = @import("generated_materialize_borrowed_argument");
    const Input = std.meta.Child(entry.Input);
    const Routing = std.meta.Child(@FieldType(Input, "route"));
    const row = @backingInt(id);
    const expressions = &self.program.expressions;
    const callee = expressions.callee(row);
    const frame: Frame = .{ .lowering = self, .body = body, .id = id };

    const cache: std.meta.Child(@FieldType(Routing, "cache")) = .{
        .count = self.cache.state.count,
        .metadata = self.cache.state.metadata.items,
        .keys = self.cache.state.keys.items,
        .key = row,
    };

    const route: Routing = .{
        .cache = &cache,
        .kind = zx.columns.view(@FieldType(Routing, "kind"), expressions.kinds[row]),
        .callee = if (callee) |function| @backingInt(function) else null,
        .value_functions = self.value_functions,
        .constructed_outputs = self.constructed_outputs,
    };

    const input: Input = .{ .frame = @ptrCast(&frame), .route = &route };

    return evaluation.invoke(entry, &input);
}

pub fn lowerBorrowedOperand(handle: *const anyopaque, id: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try borrow(frame.lowering, frame.body, @fromBackingInt(id)));
}

pub fn lowerExistingBorrowedArgument(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return existing(frame, frame.id);
}

pub fn lowerExistingBorrowedOperand(handle: *const anyopaque, id: u32) Error!u32 {
    return existing(Frame.borrow(handle), @fromBackingInt(id));
}

fn existing(frame: *const Frame, id: ir.ExprId) Error!u32 {
    const self = frame.lowering;
    const value = try self.expr(id);
    const type_id = self.program.expression(id).type_id;

    if (!self.state_active or !self.state_plan.represented(self.program, type_id)) return @backingInt(value);

    const bound = try aggregate.bind(self, frame.body, value);

    return @backingInt(try conversion.convert(self, frame.body, type_id, bound, .borrow));
}

pub fn borrowedCallOperand(handle: *const anyopaque) u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(frame.lowering.program.expression(frame.id).value.call.argument);
}

pub fn emitBorrowedCall(handle: *const anyopaque, value: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const invocation = self.program.expression(frame.id).value.call;
    const scope = @import("../state_value/root.zig").enterBorrowed(self);

    defer scope.restore();

    const cached = try self.cache.bind(self.allocator, invocation.argument, @fromBackingInt(value));

    defer cached.restore();

    return @backingInt(try @import("root.zig").borrowInvocation(self, frame.body, invocation));
}

pub fn materializeBorrowedTuple(handle: *const anyopaque) Error!u32 {
    const context = Frame.borrow(handle);
    const self = context.lowering;
    const expression = self.program.expression(context.id);
    const items = expression.value.tuple;
    var origin: @import("../construction/publication.zig").OriginBuffer = undefined;
    const entry = @import("generated_materialize_borrowed_tuple");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(handle),
        .lowering = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .sequence = @ptrCast(context.body),
        .type_id = @backingInt(expression.type_id),
        .items = @ptrCast(items),
    };

    return @backingInt(try evaluation.invokeWith(self, entry, &input));
}
