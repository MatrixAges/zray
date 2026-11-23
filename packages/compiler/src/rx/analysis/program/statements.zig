const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("builder.zig");
const Flow = @import("flow.zig");
const Module = @import("../module.zig");
const Plan = @import("control/plan.zig");
const Writer = @import("control/writer.zig");
const Invocation = @import("statements/invocation.zig");
const inlineValue = @import("expression.zig").inlineValue;
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
pub const TaskOutput = enum { None, Evaluate, Bind };

pub fn finishTask(self: *const Self, output: TaskOutput, cursor: *Writer.Cursor, row: usize, count: usize) Error!void {
    switch (output) {
        .None => self.restoreBindings(count),
        .Evaluate => {
            self.writer.evaluate(cursor, try self.evaluateValue(row, false));
            self.restoreBindings(count);
        },
        .Bind => {
            const value = try self.evaluateValue(row, false);
            const symbol = try self.defineTaskBinding(cursor, row, value);

            self.restoreBindings(count);

            try self.publishBinding(symbol);
        },
    }
}

pub fn evaluateValue(self: *const Self, row: usize, borrow: bool) Error!ir.ExprId {
    return inlineValue(self.builder, self.flow.steps.items(.value)[row].?.*, borrow);
}

pub fn defineTaskBinding(self: *const Self, cursor: *Writer.Cursor, row: usize, value: ir.ExprId) Error!ir.SymbolId {
    const builder = self.builder;
    const symbol = try builder.symbol(self.flow.steps.items(.name)[row].?, builder.expressionType(value), builder.expressionSpan(value));

    self.writer.constant(cursor, symbol, value);

    return symbol;
}

pub fn publishBinding(self: *const Self, symbol: ir.SymbolId) Error!void {
    try self.builder.bindings.append(self.builder.allocator, symbol);
}

pub fn restoreBindings(self: *const Self, count: usize) void {
    self.builder.bindings.shrinkRetainingCapacity(count);
}

pub fn parallel(self: *const Self, cursor: *Writer.Cursor, branches: []const Module.Call) Error!void {
    const first = cursor.counts.invocations;
    var published: usize = 0;

    for (branches, @as(usize, first)..) |*invocation, position| {
        const value = try self.invoke(cursor, invocation);

        published += @intFromBool(try self.writeParallelBranch(position, invocation, value));
    }

    try self.publishParallel(cursor, branches.len, published);
}

pub fn writeParallelBranch(self: *const Self, position: usize, invocation: *const Module.Call, value: ir.ExprId) Error!bool {
    const builder = self.builder;
    const symbol = if (invocation.out) |name| try builder.symbol(name, builder.expressionType(value), builder.expressionSpan(value)) else null;

    self.writer.parallelBranch(position, symbol, value);

    return symbol != null;
}

pub fn publishParallel(self: *const Self, cursor: *Writer.Cursor, count: usize, published: usize) Error!void {
    const builder = self.builder;

    try builder.bindings.ensureUnusedCapacity(builder.allocator, published);

    const tail = builder.bindings.unusedCapacitySlice()[0..published];

    self.writer.parallel(cursor, count, tail);

    builder.bindings.items.len += tail.len;
}

pub fn call(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call) Error!void {
    try self.publishCall(cursor, invocation, try self.invoke(cursor, invocation));
}

pub fn publishCall(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call, value: ir.ExprId) Error!void {
    const builder = self.builder;

    const name = invocation.out orelse {
        self.writer.evaluate(cursor, value);

        return;
    };

    const symbol = try builder.symbol(name, invocation.callee.output_type, builder.expressionSpan(value));

    self.writer.constant(cursor, symbol, value);

    try self.publishBinding(symbol);
}

fn invoke(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call) Error!ir.ExprId {
    const count = self.builder.bindings.items.len;
    var work: Invocation = .{ .call = invocation };

    try self.bindGetters(cursor, invocation);

    work.argument = if (invocation.input_omitted)
        try self.unitArgument(invocation)

    else
        try self.evaluateArgument(invocation);

    self.restoreBindings(count);

    try work.resolveStores(self.builder);
    try Invocation.Import.prepare(self.builder, invocation, &work.function);
    if (work.function.addition != null) try work.function.appendTail(self.builder);
    if (work.function.needs_initializers) try work.function.linkInitializers(self.builder, invocation);
    if (work.function.addition != null) try work.function.appendEntry(self.builder, invocation);

    return work.emit(self.builder);
}

pub fn evaluateArgument(self: *const Self, invocation: *const Module.Call) Error!ir.ExprId {
    return inlineValue(self.builder, invocation.argument, self.retain_metadata);
}

pub fn unitArgument(self: *const Self, invocation: *const Module.Call) Error!ir.ExprId {
    return direct.unit(self.builder, invocation.argument.symbols.at(0).span);
}

pub fn bindGetters(self: *const Self, cursor: *Writer.Cursor, invocation: *const Module.Call) Error!void {
    const builder = self.builder;
    const getters = invocation.getters;
    const location = invocation.argument.symbols.at(0).span;

    if (getters.len == 0) return;
    if (comptime generated) return @import("linking/store_get/host.zig").publish(builder, self.writer, cursor, getters, location);

    for (getters) |getter| {
        const slot = try builder.seedStore(getter.readSlot());
        const snapshot = try builder.seedExpression(.{ .type_id = getter.type_id, .span = location, .value = .{ .store_get = slot } });
        const symbol = try builder.symbol(getter.name, getter.type_id, location);

        self.writer.constant(cursor, symbol, snapshot);

        try builder.bindings.append(builder.allocator, symbol);
    }
}
