const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("builder.zig");
const Flow = @import("flow.zig");
const Module = @import("../module.zig");
const Plan = @import("control/plan.zig");
const Writer = @import("control/writer.zig");
const Schedule = @import("statements/schedule.zig");
const inlineValue = @import("expression.zig").inlineValue;
const Self = @This();

builder: *Builder,
flow: *const Flow,
plan: Plan,
writer: *Writer,
calls: []const Module.Call,
retain_metadata: bool,
pub fn lower(self: *const Self, owner: u32, cursor: *Writer.Cursor) Builder.Error!void {
    const unit = self.flow.units.get(owner);

    for (unit.first..unit.first + unit.count) |index| {
        const step = self.flow.steps.get(index);

        switch (step.kind) {
            .Call => try self.call(cursor, &self.calls[step.first]),
            .Parallel => try self.parallel(cursor, self.calls[step.first..][0..step.count]),
            .Return => self.writer.result(cursor, try inlineValue(self.builder, step.value.?.*, self.retain_metadata and owner == self.plan.root())),
            .Task => try self.task(cursor, step),
            .Selection => try self.selection(cursor, step),
        }
    }
}

fn task(self: *const Self, cursor: *Writer.Cursor, step: Flow.Step) Builder.Error!void {
    return switch (step.output) {
        .None => self.lowerTask(.Task, cursor, step),
        .Evaluate => self.lowerTask(.TaskWithEvaluation, cursor, step),
        .Constant => self.lowerTask(.TaskWithBinding, cursor, step),
    };
}

fn lowerTask(self: *const Self, comptime form: Schedule.Form, cursor: *Writer.Cursor, step: Flow.Step) Builder.Error!void {
    const builder = self.builder;
    const count = builder.bindings.items.len;
    var value: ir.ExprId = undefined;
    var symbol: ir.SymbolId = undefined;

    inline for (comptime Schedule.steps(form)) |action| {
        switch (action) {
            .Done => {},
            .LowerTask => try self.lower(step.first, cursor),
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

fn selection(self: *const Self, cursor: *Writer.Cursor, step: Flow.Step) Builder.Error!void {
    const subject = try inlineValue(self.builder, step.value.?.*, false);
    const first = cursor.counts.cases;
    const cases = self.flow.cases.slice();
    const bodies = cases.items(.body)[step.first..][0..step.count];
    const labels = cases.items(.value)[step.first..][0..step.count];

    for (bodies, labels, @as(usize, first)..) |unit, label, position| {
        if (label) |program| {
            try self.writeCase(.Case, unit, position, program);
        } else {
            try self.writeCase(.Default, unit, position, null);
        }
    }

    self.writer.selection(cursor, subject, step.count, step.exhaustive);
}

fn writeCase(self: *const Self, comptime form: Schedule.Form, unit: u32, position: usize, program: ?*const ir.Program) Builder.Error!void {
    var label: ?ir.ExprId = null;
    var body: ir.BlockId = undefined;

    inline for (comptime Schedule.steps(form)) |action| {
        switch (action) {
            .Done => {},
            .EvaluateLabel => label = try inlineValue(self.builder, program.?.*, false),
            .LowerBranch => body = try self.block(unit),
            .WriteCase => self.writer.selectionCase(position, label, body),
            else => unreachable,
        }
    }
}

fn block(self: *const Self, unit: u32) Builder.Error!ir.BlockId {
    const count = self.builder.bindings.items.len;
    const row = self.plan.rows[unit];
    var cursor = Writer.Cursor.init(row.first);

    defer self.builder.bindings.shrinkRetainingCapacity(count);

    try self.lower(unit, &cursor);

    return self.writer.finishBlock(&cursor, row.tag, self.plan.end(unit));
}

fn parallel(self: *const Self, cursor: *Writer.Cursor, branches: []const Module.Call) Builder.Error!void {
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

fn call(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call) Builder.Error!void {
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
            .UnitArgument => argument = try builder.expression(.{ .type_id = @fromBackingInt(@intCast(@backingInt(ir.Scalar.void))), .span = location, .value = .unit }),
            .RestoreBindings => builder.bindings.shrinkRetainingCapacity(count),
            .ResolveStores => {
                const slots = invocation.callee.stores;

                stores = try builder.allocator.alloc(u32, slots.count());

                for (stores, 0..) |*mapped, index| mapped.* = try builder.store(slots.at(index));
            },
            .ImportCallee => function = try builder.importFunction(invocation.callee, invocation.store_initializers, invocation.function_id),
            .WriteCall => call_id = try builder.expression(.{
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
        const snapshot = try builder.expression(.{ .type_id = getter.slot.type_id, .span = location, .value = .{ .store_get = slot } });
        const symbol = try builder.symbol(getter.name, getter.slot.type_id, location);

        self.writer.constant(cursor, symbol, snapshot);

        try builder.bindings.append(builder.allocator, symbol);
    }
}
