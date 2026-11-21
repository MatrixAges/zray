const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Iteration = @import("../iteration_value/root.zig");
const Action = @import("generated_expression_dispatch").Output;
const entry = @import("generated_expression_read");
const projection = @import("../access/projection/read.zig");
const path = @import("../access/projection/path.zig");
const emit = @import("../access/emit.zig");
const list = @import("../state_value/list.zig");

pub fn lower(self: *Lower, row: u32, type_id: ir.TypeId, comptime action: Action, comptime iteration: bool, context: if (iteration) *Iteration else node.ExpressionId) Lower.Error!node.ExpressionId {
    const request = comptime plan(action, iteration);
    const table = &self.program.expressions;
    const payload = if (comptime request.operand != null) table.payloads[row] else undefined;
    const operand: ir.ExprId = if (comptime request.operand) |column| @fromBackingInt(@field(table, column)[payload]) else undefined;
    const detail = if (comptime request.index) |column| @field(table, column)[payload] else undefined;
    const is_member = action == .Field or action == .TupleField;
    const target_type: ir.TypeId = if (is_member) @fromBackingInt(table.types[@backingInt(operand)]) else undefined;
    var source: ?node.ExpressionId = null;
    var result_type: ?node.ExpressionId = null;
    var key: node.ExpressionId = undefined;
    var raw = false;

    inline for (request.steps) |step| switch (step) {
        .Type => result_type = if (iteration) try self.typeExpr(type_id) else context,
        .OptionalType => result_type = if (iteration) try @import("../iteration_value/types.zig").get(context, type_id) else context,
        .Operand => source = try self.expr(operand),
        .TupleResult => if (try @import("../collections.zig").projection(self, operand, detail)) |value| return value,
        .RawMember => {
            if (@import("../access/projection/rules.zig").raw(self, target_type, false)) source = try path.lower(self, operand);

            raw = source != null;
        },
        .Anchor => if (source == null) {
            source = try path.anchor(self, operand);
        },
        .RawList => {
            source = try path.nested(self, operand);
            raw = source != null;
        },
        .List => if (source == null) {
            source = try list.expression(self, operand);
        },
        .Items => source = try emit.field(self, source.?, request.items),
        .Key => key = try self.expr(@fromBackingInt(detail)),
        .Optional => return emit.optional(self, result_type, source),
        .Reference => return @import("../access/reference.zig").lowerMode(self, @fromBackingInt(@backingInt(operand)), type_id, iteration),
        .Member => return projection.resolvedMember(self, type_id, target_type, .{ .target = operand, .index = detail }, source.?, raw, action == .TupleField, iteration),
        .Index => {
            const value = try @import("../intrinsics.zig").index(self, source.?, key);

            return if (iteration) value else projection.resolvedIndex(self, type_id, operand, value, raw);
        },
        .Length => return emit.length(self, source.?, result_type.?, iteration),
    };

    unreachable;
}

fn plan(comptime action: Action, comptime iteration: bool) @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload {
    @setEvalBranchQuota(120_000);

    var buffer: [4096]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const request = entry.executeValue(memory.allocator(), &.{ .action = action, .iteration = iteration }) catch unreachable;

    if (request.steps.len == 0) @compileError("Missing recursive expression recipe");

    return request;
}
