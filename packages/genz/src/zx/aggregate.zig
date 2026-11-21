const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const object_fields = @import("aggregate/object.zig");
const operands = @import("aggregate/operands.zig");

pub fn object(self: *Lower, id: ir.ExprId, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "object")) Lower.Error!node.ExpressionId {
    return objectMode(self, id, value, false);
}

pub fn objectValue(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    return objectMode(self, id, self.program.expression(id).value.object, true);
}

fn objectMode(self: *Lower, id: ir.ExprId, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "object"), layout: bool) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: @TypeOf(self.cache).SnapshotBuffer = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const saved = try self.cache.snapshot(temporary, value.evaluation);

    defer self.cache.restore(self.allocator, value.evaluation, saved);

    var body: std.ArrayList(node.Statement) = .empty;
    const length = value.evaluation.len;
    const counts = try temporary.alloc(u64, length);
    const references = try temporary.alloc(node.ExpressionId, length);
    const names = if (operands.generated) try temporary.alloc([]const u8, length) else &.{};
    const values = if (operands.generated) try temporary.alloc(u32, length) else &.{};

    for (value.evaluation, 0..) |item, index| {
        const name = try self.fresh("operand");
        const expression = try self.expr(item);

        if (operands.generated) {
            names[index] = name;
            values[index] = @backingInt(expression);
        } else try body.append(self.allocator, .{ .constant = .{ .name = name, .value = expression } });

        const reference = try self.builder.identifier(name);

        references[index] = reference;

        counts[index] = if (operands.generated) try self.cache.observe(self.allocator, item, reference, self.cache_reads, null) else prior: {
            const prior = self.cache_reads[@backingInt(item)];

            try self.cache.put(self.allocator, item, reference);

            break :prior prior;
        };
    }

    if (operands.generated) try operands.bind(self, temporary, &body, names, values);

    const observation: operands.Observation = .{
        .evaluation = value.evaluation,
        .prior = counts,
        .references = references,
    };

    const updated = try @import("object_update.zig").lower(self, temporary, id, &body);
    const type_id = self.program.expression(id).type_id;

    const plan = try @import("aggregate/layout.zig").plan(self, temporary, .{
        .id = id,
        .type_id = type_id,
        .layout_only = layout,
        .updated = updated != null,
        .indices = value.fields.indices[0..value.fields.len],
    });

    if (updated) |result| {
        try operands.retire(self, temporary, &body, observation);

        return finish(self, &body, if (plan.construct) try self.construct(type_id, result) else result);
    }

    const field_names = self.program.typeOf(type_id).object.names;
    const fields = try object_fields.allocate(self, temporary, value.fields.len);

    for (0..value.fields.len) |index| {
        const field = value.fields.at(index);
        const expression = try self.expr(field.value);

        const represented = switch (plan.field(index, field.index)) {
            .Direct => expression,
            .Borrowed => try @import("aggregate/borrowed.zig").field(self, expression, plan.projection.?.seed, field_names[field.index]),
            .Pointer => try @import("state_value/conversion.zig").convert(self, &body, self.program.expression(field.value).type_id, try bind(self, &body, expression), .pointer),
        };

        fields[index] = object_fields.operand(field_names, field.index, represented);
    }

    try operands.retire(self, temporary, &body, observation);

    const object_type = if (plan.projection) |projection| projection.layout else try self.layoutExpr(type_id);

    const result = try object_fields.lower(self, temporary, .{
        .type_expr = object_type,
        .names = field_names,
        .indices = value.fields.indices,
        .fields = fields,
    });

    return finish(self, &body, if (plan.construct) try self.construct(type_id, result) else result);
}

pub fn bind(self: *Lower, body: anytype, expression: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("aggregate/binding_seed.zig").bind(self, body, expression);

    return @import("aggregate/binding.zig").bind(self, body, expression);
}

pub fn finish(self: *Lower, body: anytype, result: node.ExpressionId) Lower.Error!node.ExpressionId {
    const span = try self.builder.finishStatements(body);

    return finishStored(self, span, result, null);
}

pub fn finishGuarded(self: *Lower, body: anytype, condition: node.ExpressionId, value: node.ExpressionId, fallback: node.ExpressionId) Lower.Error!node.ExpressionId {
    const span = try self.builder.finishStatements(body);

    return finishStored(self, span, value, .{ .condition = condition, .fallback = fallback });
}

pub const Guard = @import("aggregate/binding.zig").Guard;

/// The block ends at the current statement tail.
pub fn finishStored(self: *Lower, body: node.Block, value: node.ExpressionId, guard: ?Guard) Lower.Error!node.ExpressionId {
    std.debug.assert(@as(usize, body.start) + body.len == self.builder.nodes.statements.tags.items.len);

    if (!@import("genz_options").generated_analysis) {
        const result = if (guard) |check| try self.builder.expression(.{ .conditional = .{
            .condition = check.condition,
            .yes = value,
            .no = check.fallback,
        } }) else value;

        return @import("aggregate/binding_seed.zig").finish(self, body, result);
    }

    const binding = @import("aggregate/binding.zig");

    if (guard) |check| return binding.finishGuarded(self, body, value, check);

    return binding.finish(self, body, value);
}
