const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const object_fields = @import("../aggregate/object.zig");
const operands = @import("../aggregate/operands.zig");
const borrowed_argument = @import("borrowed_argument.zig");
const generated = @import("genz_options").generated_analysis;
const routing = if (generated) @import("generated_value_argument_route") else void;
const Route = if (generated) @typeInfo(@typeInfo(@TypeOf(routing.executeValue)).@"fn".return_type.?).error_union.payload else enum { Existing, Object, Tuple, Call };

pub fn borrow(self: *Lower, body: *std.ArrayList(node.Statement), id: ir.ExprId) Lower.Error!node.ExpressionId {
    switch (route(self, id)) {
        .Object => return object(self, body, id),
        .Tuple => {
            const expression = self.program.expression(id);
            const items = expression.value.tuple;
            const values = try self.allocator.alloc(node.ExpressionId, items.len);

            for (items, values) |item, *value| value.* = try aggregate.bind(self, body, try borrow(self, body, item));

            const layout = try @import("../types.zig").get(self, self.abi_layouts, expression.type_id);

            return borrowed_argument.lower(self, body, .{ .tuple = .{ .layout = layout, .values = values } });
        },
        .Call => {
            const invocation = self.program.expression(id).value.call;
            const argument = try borrow(self, body, invocation.argument);
            const active = self.state_active;
            const types = self.types;
            const layouts = self.layouts;
            self.state_active = false;
            self.types = self.abi_types;
            self.layouts = self.abi_layouts;

            defer {
                self.state_active = active;
                self.types = types;
                self.layouts = layouts;
            }

            const cached = try self.cache.exchange(self.allocator, invocation.argument, argument);

            defer self.cache.restoreEntry(self.allocator, invocation.argument, cached);

            return @import("root.zig").borrowInvocation(self, body, invocation);
        },
        .Existing => return existing(self, body, id),
    }
}

fn route(self: *const Lower, id: ir.ExprId) Route {
    const row = @backingInt(id);
    const expressions = &self.program.expressions;
    const kind = expressions.kinds[row];
    const callee = expressions.callee(row);

    if (comptime !generated) {
        if (self.cache.contains(id)) return .Existing;

        if (callee) |function| {
            const index = @backingInt(function);

            return if (self.value_functions[index] and self.constructed_outputs[index]) .Call else .Existing;
        }

        return switch (kind) {
            .Object => .Object,
            .Tuple => .Tuple,
            else => .Existing,
        };
    }

    const Input = std.meta.Child(routing.Input);

    const cache: std.meta.Child(@FieldType(Input, "cache")) = .{
        .count = self.cache.state.count,
        .metadata = self.cache.state.metadata.items,
        .keys = self.cache.state.keys.items,
        .key = row,
    };

    const input: Input = .{
        .cache = &cache,
        .kind = zx.columns.view(@FieldType(Input, "kind"), kind),
        .callee = if (callee) |function| @backingInt(function) else null,
        .value_functions = self.value_functions,
        .constructed_outputs = self.constructed_outputs,
    };

    var storage = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(routing.executeValue, storage.allocator(), &input) catch unreachable;
}

fn object(self: *Lower, body: *std.ArrayList(node.Statement), id: ir.ExprId) Lower.Error!node.ExpressionId {
    const expression = self.program.expression(id);
    const value = expression.value.object;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: @TypeOf(self.cache).SnapshotBuffer = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const saved = try self.cache.snapshot(temporary, value.evaluation);

    defer self.cache.restore(self.allocator, value.evaluation, saved);

    const counts = try temporary.alloc(u64, value.evaluation.len);
    const evaluated = try temporary.alloc(node.ExpressionId, value.evaluation.len);

    for (value.evaluation, 0..) |item, index| {
        evaluated[index] = try aggregate.bind(self, body, try borrow(self, body, item));
        counts[index] = self.cache_reads[@backingInt(item)];

        const cached = if (self.state_active)
            try @import("../state_value/conversion.zig").convert(self, body, self.program.expression(item).type_id, evaluated[index], .value)
        else
            evaluated[index];

        try self.cache.put(self.allocator, item, cached);
    }

    const field_names = self.program.typeOf(expression.type_id).object.names;
    const fields = try object_fields.allocate(self, temporary, value.fields.len);

    for (0..value.fields.len) |index| {
        const field = value.fields.at(index);

        fields[index] = object_fields.operand(field_names, field.index, try existing(self, body, field.value));
    }

    try operands.retire(self, temporary, body, .{
        .evaluation = value.evaluation,
        .prior = counts,
        .references = evaluated,
    });

    const object_type = try @import("../types.zig").get(self, self.abi_layouts, expression.type_id);

    return borrowed_argument.lower(self, body, .{ .object = .{
        .scratch = temporary,
        .request = .{
            .type_expr = object_type,
            .names = field_names,
            .indices = value.fields.indices,
            .fields = fields,
        },
    } });
}

fn existing(self: *Lower, body: *std.ArrayList(node.Statement), id: ir.ExprId) Lower.Error!node.ExpressionId {
    const value = try self.expr(id);
    const type_id = self.program.expression(id).type_id;

    if (!self.state_active or !self.state_plan.represented(self.program, type_id)) return value;

    const bound = try aggregate.bind(self, body, value);

    return @import("../state_value/conversion.zig").convert(self, body, type_id, bound, .borrow);
}
