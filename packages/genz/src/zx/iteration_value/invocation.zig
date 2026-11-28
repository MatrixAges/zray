const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const evaluation = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;

const ArgumentHost = struct {
    context: *Context,
    store_0: *Binding,
    const Entry = @import("generated_lower_iteration_call");
    const Binding = std.meta.Child(@FieldType(Entry.zx_pending, "store_0"));

    pub fn commit(self: *ArgumentHost, pending: anytype) Lower.Error!void {
        const next = pending.store_0 orelse return;
        const context = self.context;

        try install(
            context,
            context.active_body.?,
            @fromBackingInt(next.operand),
            @fromBackingInt(next.operand_type),
            @fromBackingInt(next.value),
        );

        self.store_0.* = next;
    }
};

pub fn lower(self: *Context, id: ir.ExprId, row: ir.ExpressionRow, value_call: bool) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const operand = row.value.call.argument;
    const operand_type = lowering.program.expressions.types[@backingInt(operand)];
    const previous = self.argument;
    const previous_binding = self.argument_binding;
    const previous_body = self.active_body;
    var body: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;
    self.argument_binding = null;
    self.active_body = &body;

    defer {
        if (self.argument_binding) |binding| binding.restore();

        self.argument = previous;
        self.argument_binding = previous_binding;
        self.active_body = previous_body;
    }

    defer if (generated) body.deinit();

    if (!generated) {
        const value = try lowering.expr(operand);
        const bound = try aggregate.bind(lowering, &body, value);

        try install(self, &body, operand, @fromBackingInt(operand_type), bound);

        const invocation = if (value_call)
            try @import("../value_call/root.zig").invocation(lowering, row.value.call)
        else
            try lowering.regular(id);

        const result = try aggregate.bind(lowering, &body, invocation);
        const converted = try @import("conversion.zig").convert(self, row.type_id, result, false);

        return aggregate.finish(lowering, &body, converted);
    }

    const entry = @import("generated_lower_iteration_call");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(&body),
        .call_id = @backingInt(id),
        .operand = @backingInt(operand),
        .operand_type = operand_type,
        .result_type = @backingInt(row.type_id),
        .value_call = value_call,
    };

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var slot: ArgumentHost.Binding = &.{ .operand = 0, .operand_type = 0, .value = 0 };
    var host: ArgumentHost = .{ .context = self, .store_0 = &slot };

    const lowered = entry.executeIn(memory.allocator(), &input, &host) catch |err|
        return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(lowered);
}

fn install(context: *Context, body: *Context.Statements, argument: ir.ExprId, type_id: ir.TypeId, value: node.ExpressionId) Lower.Error!void {
    const self = context.lowering;
    const input = try @import("borrow.zig").lower(context, body, type_id, value);

    context.argument = .{ .id = argument, .value = input };
    context.argument_binding = try self.cache.bind(self.allocator, argument, input);
}

pub fn convertIterationCall(handle: *anyopaque, result_type: u32, value: u32) Lower.Error!u32 {
    const context = evaluation.borrow(handle).iteration_value.?;

    return @backingInt(try @import("conversion.zig").convert(context, @fromBackingInt(result_type), @fromBackingInt(value), false));
}
