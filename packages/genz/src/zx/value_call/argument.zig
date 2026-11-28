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

pub fn borrow(self: *Lower, body: anytype, id: ir.ExprId) Error!node.ExpressionId {
    if (comptime !generated) return @import("argument_seed.zig").borrow(self, body, id);

    const entry = @import("generated_materialize_borrowed_argument");
    const Input = std.meta.Child(entry.Input);
    const Routing = std.meta.Child(@FieldType(Input, "route"));
    const row = @backingInt(id);
    const expressions = &self.program.expressions;
    const callee = expressions.callee(row);

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

    const operand: ?u32 = if (expressions.kinds[row] == .Call)
        @backingInt(self.program.expression(id).value.call.argument)

    else
        null;

    const items: []const u32 = if (expressions.kinds[row] == .Tuple)
        @ptrCast(self.program.expression(id).value.tuple)

    else
        &.{};

    const input: Input = .{
        .lowering = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(body),
        .route = &route,
        .id = row,
        .type_id = expressions.types[row],
        .operand = operand,
        .items = items,
    };

    return evaluation.invokeWith(self, entry, &input);
}

pub fn lowerBorrowedOperand(writer: *anyopaque, sequence: *anyopaque, id: u32) Error!u32 {
    const self = evaluation.borrow(writer);
    const body: *Sequence = @ptrCast(@alignCast(sequence));

    return @backingInt(try borrow(self, body, @fromBackingInt(id)));
}

pub fn lowerExistingBorrowedOperand(writer: *anyopaque, sequence: *anyopaque, raw: u32) Error!u32 {
    const self = evaluation.borrow(writer);
    const body: *Sequence = @ptrCast(@alignCast(sequence));
    const id: ir.ExprId = @fromBackingInt(raw);
    const value = try self.expr(id);
    const type_id = self.program.expression(id).type_id;

    if (!self.state_active or !self.state_plan.represented(self.program, type_id)) return @backingInt(value);

    const bound = try aggregate.bind(self, body, value);

    return @backingInt(try conversion.convert(self, body, type_id, bound, .borrow));
}

pub fn emitBorrowedCall(writer: *anyopaque, sequence: *anyopaque, id: u32, value: u32) Error!u32 {
    const self = evaluation.borrow(writer);
    const body: *Sequence = @ptrCast(@alignCast(sequence));
    const invocation = self.program.expression(@fromBackingInt(id)).value.call;
    const scope = @import("../state_value/root.zig").enterBorrowed(self);

    defer scope.restore();

    const cached = try self.cache.bind(self.allocator, invocation.argument, @fromBackingInt(value));

    defer cached.restore();

    return @backingInt(try @import("root.zig").borrowInvocation(self, body, invocation));
}
