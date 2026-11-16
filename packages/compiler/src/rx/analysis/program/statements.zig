const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("builder.zig");
const Flow = @import("flow.zig");
const Module = @import("../module.zig");
const Plan = @import("control/plan.zig");
const Writer = @import("control/writer.zig");
const Schedule = @import("statements/schedule.zig");
const inlineValue = @import("expression.zig").inlineValue;
const write_call = @import("linking/call/host.zig");
const direct = @import("linking/direct.zig");
const generated = @import("rx_options").generated_graph;
const Self = @This();
pub const Error = Builder.Error;
pub const lower = @import("statements/traversal.zig").lower;

builder: *Builder,
flow: *const Flow,
plan: Plan,
writer: *Writer,
calls: []const Module.Call,
retain_metadata: bool,
pub fn finishTask(self: *const Self, cursor: *Writer.Cursor, step: Flow.Step, count: usize) Builder.Error!void {
    return switch (step.output) {
        .None => self.lowerTask(.Task, cursor, step, count),
        .Evaluate => self.lowerTask(.TaskWithEvaluation, cursor, step, count),
        .Constant => self.lowerTask(.TaskWithBinding, cursor, step, count),
    };
}

fn lowerTask(self: *const Self, comptime form: Schedule.Form, cursor: *Writer.Cursor, step: Flow.Step, count: usize) Builder.Error!void {
    const builder = self.builder;
    var value: ir.ExprId = undefined;
    var symbol: ir.SymbolId = undefined;

    inline for (comptime Schedule.steps(form)) |action| {
        switch (action) {
            .Done, .LowerTask => {},
            .EvaluateTaskOutput => value = try inlineValue(builder, step.value.?.*, false),
            .WriteEvaluation => self.writer.evaluate(cursor, value),
            .DefineTaskBinding => {
                symbol = try builder.symbol(step.name.?, builder.expressionType(value), builder.expressionSpan(value));

                self.writer.constant(cursor, symbol, value);
            },
            .RestoreBindings => builder.bindings.shrinkRetainingCapacity(count),
            .PublishTaskBinding => try builder.bindings.append(builder.allocator, symbol),
            else => unreachable,
        }
    }
}

pub fn caseLabel(self: *const Self, program: ?*const ir.Program) Builder.Error!?ir.ExprId {
    const label = program orelse return null;

    inline for (comptime Schedule.steps(.Case)) |action| {
        switch (action) {
            .Done, .LowerBranch, .WriteCase => {},
            .EvaluateLabel => return try inlineValue(self.builder, label.*, false),
            else => unreachable,
        }
    }

    unreachable;
}

pub fn parallel(self: *const Self, cursor: *Writer.Cursor, branches: []const Module.Call) Builder.Error!void {
    const builder = self.builder;
    const first = cursor.counts.invocations;
    var published: usize = 0;

    for (branches, @as(usize, first)..) |*invocation, position| {
        const value = try self.invoke(cursor, invocation);
        const symbol = if (invocation.out) |name| try builder.symbol(name, builder.expressionType(value), builder.expressionSpan(value)) else null;

        self.writer.parallelBranch(position, symbol, value);

        published += @intFromBool(symbol != null);
    }

    try builder.bindings.ensureUnusedCapacity(builder.allocator, published);

    const tail = builder.bindings.unusedCapacitySlice()[0..published];

    self.writer.parallel(cursor, branches.len, tail);

    builder.bindings.items.len += tail.len;
}

pub fn call(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call) Builder.Error!void {
    const builder = self.builder;
    const value = try self.invoke(cursor, invocation);

    const name = invocation.out orelse {
        self.writer.evaluate(cursor, value);

        return;
    };

    const symbol = try builder.symbol(name, invocation.callee.output_type, builder.expressionSpan(value));

    self.writer.constant(cursor, symbol, value);

    try builder.bindings.append(builder.allocator, symbol);
}

fn invoke(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call) Builder.Error!ir.ExprId {
    if (invocation.input_omitted) return self.lowerCall(.CallWithoutArgument, cursor, invocation);

    return self.lowerCall(.CallWithArgument, cursor, invocation);
}

fn lowerCall(self: *const Self, comptime form: Schedule.Form, cursor: *Writer.Cursor, invocation: *const Module.Call) Builder.Error!ir.ExprId {
    const builder = self.builder;
    const count = builder.bindings.items.len;
    const location = invocation.argument.symbols.at(0).span;
    var argument: ir.ExprId = undefined;
    var stores: []u32 = undefined;
    var function: ir.FunctionId = undefined;
    var call_id: ir.ExprId = undefined;

    inline for (comptime Schedule.steps(form)) |action| {
        switch (action) {
            .Done => {},
            .BindGetters => try self.bindGetters(cursor, invocation.getters, location),
            .EvaluateArgument => argument = try inlineValue(builder, invocation.argument, self.retain_metadata),
            .UnitArgument => argument = try direct.unit(builder, location),
            .RestoreBindings => builder.bindings.shrinkRetainingCapacity(count),
            .ResolveStores => {
                const slots = invocation.callee.stores;

                stores = if (comptime generated)
                    try write_call.prepare(builder, slots.count())

                else
                    try builder.allocator.alloc(u32, slots.count());

                if (comptime generated) {
                    try @import("store/bind.zig").write(builder, slots, stores);
                } else {
                    for (stores, 0..) |*mapped, index| mapped.* = try builder.store(slots.at(index));
                }
            },
            .ImportCallee => function = try builder.importFunction(invocation.callee, invocation.callee_suffix, invocation.store_initializers, invocation.function_id),
            .WriteCall => call_id = if (comptime generated)
                try write_call.publish(builder, function, argument, invocation.callee.output_type, stores.len)
            else
                try builder.seedExpression(.{
                    .type_id = invocation.callee.output_type,
                    .span = builder.expressionSpan(argument),
                    .value = .{ .call = .{ .function = function, .argument = argument, .stores = stores } },
                }),
            else => unreachable,
        }
    }

    return call_id;
}

fn bindGetters(self: *const Self, cursor: *Writer.Cursor, getters: @FieldType(Module.Call, "getters"), location: zx.Span) Builder.Error!void {
    const builder = self.builder;

    for (getters) |getter| {
        const slot = try builder.store(getter.slot);
        const snapshot = try direct.storeGet(builder, slot, getter.slot.type_id, location);
        const symbol = try builder.symbol(getter.name, getter.slot.type_id, location);

        self.writer.constant(cursor, symbol, snapshot);

        try builder.bindings.append(builder.allocator, symbol);
    }
}
