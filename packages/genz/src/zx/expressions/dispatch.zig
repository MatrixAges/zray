const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const entry = @import("generated_expression_dispatch");
const read = @import("read.zig");
const tasks = @import("../tasks/root.zig");
const Kind = std.meta.Child(@FieldType(ir.ExpressionTable, "kinds"));
pub const Action = entry.Output;

pub fn lower(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const table = &self.program.expressions;
    const row = @backingInt(id);
    const type_id: ir.TypeId = @fromBackingInt(table.types[row]);
    const value_type = try self.typeExpr(type_id);
    const actions = comptime dispatch();

    return switch (actions[@backingInt(table.kinds[row])]) {
        inline .Wrap, .Unwrap, .Field, .TupleField, .Index, .Length, .Reference => |action| read.lower(self, row, type_id, action, false, value_type),
        .Literal => @import("../literals.zig").lower(self, id, value_type),
        .Store => @import("../access/store.zig").lower(self, table.stores[table.payloads[row]], type_id),
        .Task => tasks.start(self, id, false),
        .Wait => tasks.wait(self, @fromBackingInt(table.awaits[table.payloads[row]])),
        .Cancel => tasks.cancel(self, @fromBackingInt(table.cancellations[table.payloads[row]])),
        .Parallel => tasks.parallel(self, type_id, self.program.expression(id).value.parallel),
        .Capture => @import("../capture.zig").lower(self, type_id, @fromBackingInt(table.captures[table.payloads[row]])),
        .Unary => unary(self, table, table.payloads[row]),
        .Binary => binary(self, table, table.payloads[row]),
        .Conditional => @import("../selection/conditional.zig").lower(self, self.program.expression(id).value.conditional),
        .Match => @import("../match.zig").lower(self, self.program.expression(id).value.match_expr),
        .Object => @import("../aggregate.zig").object(self, id, self.program.expression(id).value.object),
        .Sequence => sequence(self, id),
        .Collection => @import("../collections.zig").lower(self, id),
        .Transform => @import("../transform.zig").lower(self, id, self.program.expression(id).value.transform),
        .Scope => @import("../scope.zig").lower(self, self.program.expression(id).value.scope),
        .Iteration => @import("../iteration.zig").lower(self, id, self.program.expression(id).value.iteration),
        .Update => @import("../list_update.zig").lower(self, id),
        .Call => @import("../regular_call/root.zig").lower(self, self.program.expression(id).value.call),
        .Empty, .Invalid => unreachable,
    };
}

fn sequence(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const value = self.program.expression(id);

    const items = switch (value.value) {
        .list, .tuple, .template => |items| items,
        else => unreachable,
    };

    return @import("../aggregate/sequence.zig").lower(self, id, value, items, false);
}

fn unary(self: *Lower, table: *const ir.ExpressionTable, payload: u32) Lower.Error!node.ExpressionId {
    return @import("../operators/unary.zig").lower(self, table.unary_operators[payload], @fromBackingInt(table.unary_operands[payload]));
}

fn binary(self: *Lower, table: *const ir.ExpressionTable, payload: u32) Lower.Error!node.ExpressionId {
    return @import("../operators/binary.zig").lower(self, table.binary_operators[payload], @fromBackingInt(table.binary_left[payload]), @fromBackingInt(table.binary_right[payload]));
}

fn dispatch() [@typeInfo(Kind).@"enum".field_names.len]Action {
    @setEvalBranchQuota(50_000);

    var actions: [@typeInfo(Kind).@"enum".field_names.len]Action = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    comptime @import("../../node/view.zig").compatible(Kind, entry.Input);

    for (std.enums.values(Kind)) |kind| {
        const action = entry.executeValue(fixed.allocator(), zx.columns.view(entry.Input, kind)) catch unreachable;

        if (action == .Invalid) @compileError("Expression has no lowering action: " ++ @tagName(kind));

        actions[@backingInt(kind)] = action;
    }

    return actions;
}
