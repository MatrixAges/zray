const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const evaluate = @import("../evaluate.zig");
const borrow = evaluate.borrow;
const Mode = evaluate.Api.Representation;
const Error = Lower.Error;
const tasks = @import("../../tasks/root.zig");
const aggregate = @import("../../aggregate.zig");
const collections = @import("../../collections.zig");
const scope = @import("../../scope.zig");
const iteration = @import("../../iteration.zig");
const mode_types = @import("../../iteration_value/types.zig");
const value_call = @import("../../value_call/root.zig");

pub fn lowerExpression(frame: *const anyopaque, id: u32, checked: bool, cached: ?u32) Error!u32 {
    return @backingInt(try borrow(frame).exprWithCache(@fromBackingInt(id), .{ .checked = checked, .value = cached }));
}

pub fn lowerRegular(frame: *const anyopaque, id: u32, checked: bool, cached: ?u32) Error!u32 {
    return @backingInt(try borrow(frame).regularWithCache(@fromBackingInt(id), .{ .checked = checked, .value = cached }));
}

pub fn lowerValueExpression(frame: *const anyopaque, id: u32) Error!u32 {
    return @backingInt(try value_call.expression(borrow(frame), @fromBackingInt(id)));
}

pub fn lowerType(frame: *const anyopaque, id: u32, in_iteration: bool) Error!u32 {
    const self = borrow(frame);

    return @backingInt(if (in_iteration)
        try mode_types.get(self.iteration_value.?, @fromBackingInt(id))
    else
        try self.typeExpr(@fromBackingInt(id)));
}

pub fn materializeType(frame: *const anyopaque, id: u32, representation: evaluate.Api.StoredType) Error!u32 {
    return @backingInt(try @import("../../types.zig").resource(borrow(frame), @fromBackingInt(id), representation));
}

pub fn loweringOrigin(frame: *const anyopaque, id: u32) Error![]const u8 {
    return @import("../../state_value/origin.zig").name(borrow(frame), @fromBackingInt(id));
}

pub fn lowerLiteral(frame: *const anyopaque, id: u32, value_type: u32) Error!u32 {
    return @backingInt(try @import("../../literals.zig").lower(borrow(frame), @fromBackingInt(id), @fromBackingInt(value_type)));
}

pub fn lowerStore(frame: *const anyopaque, id: u32) Error!u32 {
    const self = borrow(frame);
    const table = &self.program.expressions;

    return @backingInt(try @import("../../access/store.zig").lower(self, table.stores[table.payloads[id]], @fromBackingInt(table.types[id])));
}

pub fn lowerTask(frame: *const anyopaque, id: u32) Error!u32 {
    return @backingInt(try tasks.start(borrow(frame), @fromBackingInt(id), false));
}

pub fn lowerWait(frame: *const anyopaque, id: u32) Error!u32 {
    const self = borrow(frame);
    const table = &self.program.expressions;

    return @backingInt(try tasks.wait(self, @fromBackingInt(table.awaits[table.payloads[id]])));
}

pub fn lowerCancel(frame: *const anyopaque, id: u32) Error!u32 {
    const self = borrow(frame);
    const table = &self.program.expressions;

    return @backingInt(try tasks.cancel(self, @fromBackingInt(table.cancellations[table.payloads[id]])));
}

pub fn lowerParallel(frame: *const anyopaque, id: u32) Error!u32 {
    const self = borrow(frame);
    const row = self.program.expression(@fromBackingInt(id));

    return @backingInt(try tasks.parallel(self, row.type_id, row.value.parallel));
}

pub fn lowerCapture(frame: *const anyopaque, id: u32, value: bool) Error!u32 {
    const self = borrow(frame);
    const row = self.program.expression(@fromBackingInt(id));
    const capture = @import("../../capture.zig");

    return @backingInt(if (value) try capture.lowerValue(self, row.type_id, row.value.capture) else try capture.lower(self, row.type_id, row.value.capture));
}

pub fn readOperatorOperand(frame: *const anyopaque, id: u32, right: bool) u32 {
    const table = &borrow(frame).program.expressions;
    const payload = table.payloads[id];

    if (table.kinds[id] == .Unary) return table.unary_operands[payload];

    return if (right) table.binary_right[payload] else table.binary_left[payload];
}

pub fn readExpressionType(frame: *const anyopaque, id: u32) u32 {
    return borrow(frame).program.expressions.types[id];
}

pub fn writeUnary(frame: *const anyopaque, id: u32, operand: u32) Error!u32 {
    const self = borrow(frame);
    const table = &self.program.expressions;

    return @backingInt(try @import("../../operators/unary.zig").emit(self, table.unary_operators[table.payloads[id]], @fromBackingInt(operand)));
}

pub fn readBinaryOperator(frame: *const anyopaque, id: u32) u8 {
    const table = &borrow(frame).program.expressions;

    return @backingInt(table.binary_operators[table.payloads[id]]);
}

pub fn writeBinary(frame: *const anyopaque, operator: u8, left_ir: u32, right_ir: u32, left: u32, right: u32, operand_type: u32) Error!u32 {
    const Operator = std.meta.Child(@FieldType(ir.ExpressionTable, "binary_operators"));
    const emission = @import("../../operators/binary.zig");

    const values: emission.Operands = .{
        .left_ir = @fromBackingInt(left_ir),
        .right_ir = @fromBackingInt(right_ir),
        .left = @fromBackingInt(left),
        .right = @fromBackingInt(right),
        .type_expr = @fromBackingInt(operand_type),
    };

    return @backingInt(try emission.emit(borrow(frame), @as(Operator, @fromBackingInt(@intCast(operator))), values));
}

pub fn readConditionalOperand(frame: *const anyopaque, id: u32, part: evaluate.Api.ConditionalPart) u32 {
    const row = borrow(frame).program.expression(@fromBackingInt(id)).value.conditional;

    return @backingInt(switch (part) {
        .Condition => row.condition,
        .Yes => row.yes,
        .No => row.no,
    });
}

pub fn writeConditional(frame: *const anyopaque, condition: u32, yes: u32, no: u32) Error!u32 {
    return @backingInt(try @import("../../selection/conditional.zig").construct(borrow(frame), @fromBackingInt(condition), @fromBackingInt(yes), @fromBackingInt(no)));
}

pub fn lowerMatch(frame: *const anyopaque, id: u32, value: bool) Error!u32 {
    const self = borrow(frame);
    const selected = self.program.expression(@fromBackingInt(id)).value.match_expr;
    const selection = @import("../../match.zig");

    return @backingInt(if (value) try selection.lowerValue(self, selected) else try selection.lower(self, selected));
}

pub fn lowerAggregate(frame: *const anyopaque, id: u32, mode: Mode) Error!u32 {
    const self = borrow(frame);
    const expression: ir.ExprId = @fromBackingInt(id);
    const row = self.program.expression(expression);

    if (mode == .Iteration) return @backingInt(if (row.value == .list)
        try @import("../../iteration_value/list.zig").lower(self.iteration_value.?, row.type_id, row.value.list)
    else
        try @import("../../iteration_value/aggregate.zig").lower(self.iteration_value.?, expression));

    return @backingInt(switch (row.value) {
        .object => |value| if (mode == .Value) try aggregate.objectValue(self, expression) else try aggregate.object(self, expression, value),
        .list, .tuple, .template => |items| try @import("../../aggregate/sequence.zig").lower(self, expression, row, items, mode == .Value),
        else => unreachable,
    });
}

pub fn lowerCollection(frame: *const anyopaque, id: u32, mode: Mode) Error!u32 {
    const self = borrow(frame);
    const expression: ir.ExprId = @fromBackingInt(id);
    const type_id: ir.TypeId = @fromBackingInt(self.program.expressions.types[id]);

    return @backingInt(switch (mode) {
        .Regular => try collections.lower(self, expression),
        .Value => try collections.lowerValue(self, expression, try self.layoutExpr(type_id)),
        .Iteration => try collections.lowerValue(self, expression, try mode_types.get(self.iteration_value.?, type_id)),
    });
}

pub fn lowerTransform(frame: *const anyopaque, id: u32) Error!u32 {
    const self = borrow(frame);
    const expression: ir.ExprId = @fromBackingInt(id);

    return @backingInt(try @import("../../transform.zig").lower(self, expression, self.program.expression(expression).value.transform));
}

pub fn lowerScope(frame: *const anyopaque, id: u32, mode: Mode) Error!u32 {
    const self = borrow(frame);
    const value = self.program.expression(@fromBackingInt(id)).value.scope;

    return @backingInt(switch (mode) {
        .Regular => try scope.lower(self, value),
        .Value => try scope.lowerValue(self, value),
        .Iteration => try @import("../../iteration_value/scope.zig").lower(self.iteration_value.?, value),
    });
}

pub fn lowerIteration(frame: *const anyopaque, id: u32, value: bool) Error!u32 {
    const self = borrow(frame);
    const expression: ir.ExprId = @fromBackingInt(id);
    const loop = self.program.expression(expression).value.iteration;

    return @backingInt(if (value) try iteration.lowerValue(self, expression, loop) else try iteration.lower(self, expression, loop));
}

pub fn lowerCall(frame: *const anyopaque, id: u32, mode: Mode, value: bool) Error!u32 {
    const self = borrow(frame);
    const expression: ir.ExprId = @fromBackingInt(id);
    const row = self.program.expression(expression);

    return @backingInt(switch (mode) {
        .Regular => try @import("../../regular_call/root.zig").lower(self, row.value.call),
        .Value => try value_call.invocation(self, row.value.call),
        .Iteration => try @import("../../iteration_value/invocation.zig").lower(self.iteration_value.?, expression, row, value),
    });
}

pub fn lowerUpdate(frame: *const anyopaque, id: u32) Error!u32 {
    const self = borrow(frame);

    return @backingInt(try @import("../../list_update.zig").lower(self, @fromBackingInt(id)));
}

pub fn lowerMutation(frame: *const anyopaque, id: u32) Error!u32 {
    return @backingInt(try @import("../../iteration_value/mutation.zig").lower(borrow(frame).iteration_value.?, @fromBackingInt(id)));
}

pub fn reuseIteration(frame: *const anyopaque, id: u32) Error!void {
    const self = borrow(frame);

    return self.iteration_value.?.reads.increment(self.allocator, @fromBackingInt(id));
}

pub fn lowerUnpack(frame: *const anyopaque, id: u32, value: u32) Error!u32 {
    const self = borrow(frame);

    return @backingInt(try @import("../../iteration_value/evaluation.zig").unpack(self.iteration_value.?, @fromBackingInt(id), @fromBackingInt(value)));
}

pub fn lowerDereference(frame: *const anyopaque, value: u32) Error!u32 {
    return @backingInt(try @import("../../value_call/emission.zig").emit(borrow(frame), null, .{ .value = @fromBackingInt(value) }));
}

pub fn invalidLowering() u32 {
    unreachable;
}
