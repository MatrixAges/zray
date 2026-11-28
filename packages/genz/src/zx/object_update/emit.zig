const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const fields = @import("../../node/import_fields.zig");
const aggregate = @import("../aggregate.zig");
const Lower = @import("../lower.zig");
const Change = @import("../object_update.zig").Change;
const Plan = @import("matching.zig").Plan;
const Sequence = @import("../../node/blocks.zig").Sequence;

pub fn expression(self: *Lower, temporary: std.mem.Allocator, plan: Plan, body: *Sequence) Lower.Error!node.ExpressionId {
    const change = plan.change;
    const generated = @import("generated_object_update_expression");
    const Input = std.meta.Child(generated.Input);
    const Write = std.meta.Child(@FieldType(Input, "source"));
    const Changes = std.meta.Child(std.meta.Child(@FieldType(Write, "changes")));
    const Boxed = std.meta.Child(std.meta.Child(@FieldType(Input, "boxed")));
    const name = try self.fresh("updated");
    const layout = try self.layoutExpr(change.type_id);
    const selected = self.state_plan.selected[@backingInt(change.type_id)];
    const reference = try self.expr(change.reference);
    const initial = if (selected) reference else try aggregate.bind(self, body, reference);
    const multiple = selected and plan.positions.len != 0;
    const value: node.ExpressionId = if (selected and !multiple) try self.expr(change.field.value) else @fromBackingInt(0);
    const value_name = try self.fresh("operand");
    const label = try self.fresh("block");
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Write, "types")), self.program.types);
    var changes: Changes = undefined;

    if (multiple) {
        const object = self.program.expression(change.object.?).value.object;
        const values = try temporary.alloc(u32, plan.positions.len);

        for (values, plan.positions) |*item, position| item.* = @backingInt(try self.expr(object.fields.at(position).value));

        changes = .{
            .indices = object.fields.indices,
            .positions = plan.positions,
            .values = values,
        };
    }

    const boxed: ?Boxed = if (selected) null else overlay: {
        const values = try temporary.alloc(?u32, self.program.typeOf(change.type_id).object.len);

        @memset(values, null);

        if (plan.positions.len == 0) {
            values[change.field.index] = @backingInt(try boxedOperand(self, body, change.field.value));
        } else {
            const object = self.program.expression(change.object.?).value.object;

            for (plan.positions) |position| {
                const member = object.fields.at(position);

                values[member.index] = @backingInt(try boxedOperand(self, body, member.value));
            }
        }

        break :overlay .{ .values = values, .field_base = @intCast(self.builder.nodes.field_columns.count()) };
    };

    const source: Write = .{
        .types = &types,
        .type_id = @backingInt(change.type_id),
        .field = change.field.index,
        .target_name = name,
        .value_name = value_name,
        .value = @backingInt(value),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .clear_origin = selected,
        .changes = if (multiple) &changes else null,
    };

    const input: Input = .{ .source = &source, .layout = @backingInt(layout), .initial = @backingInt(initial), .label = label, .boxed = if (boxed) |*item| item else null };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const expressions = view.join(output.expressions.*, output.forms.*);
    const emitted = view.join(output.statements.*, output.variables.*);

    try append(self, &self.builder.nodes.expressions, &expressions);
    try append(self, &self.builder.nodes.statements, &emitted);

    if (output.fields) |members| {
        fields.append(self.allocator, &self.builder.nodes.field_columns, members) catch |err| return @import("../construction/publication.zig").failure(err);
    }

    return @fromBackingInt(output.root);
}

pub fn statementBlock(self: *Lower, change: Change) Lower.Error!node.Block {
    const generated = @import("generated_object_update_statements");
    const Input = std.meta.Child(generated.Input);
    const value = try self.expr(change.field.value);
    const name = try self.fresh("operand");
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);

    const input: Input = .{
        .types = &types,
        .type_id = @backingInt(change.type_id),
        .field = change.field.index,
        .target_name = self.names[@backingInt(change.previous)],
        .value_name = name,
        .value = @backingInt(value),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .clear_origin = true,
        .changes = null,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const expressions = view.join(output.expressions.*, output.forms.*);
    const statements = view.join(output.statements.*, output.variables.*);

    try append(self, &self.builder.nodes.expressions, &expressions);

    const block = try self.builder.publishStatements(&statements);

    self.used[@backingInt(change.previous)] = true;

    return block;
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    rows.append(self.allocator, target, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}

fn boxedOperand(self: *Lower, body: *Sequence, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const bound = try aggregate.bind(self, body, try self.expr(id));
    const value = try @import("../state_value/conversion.zig").convert(self, body, self.program.expression(id).type_id, bound, .pointer);

    return if (value == bound) bound else aggregate.bind(self, body, value);
}
