const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const Iteration = @import("../iteration_value/root.zig");
const regular_entry = @import("generated_lower_regular");
const value_entry = @import("generated_lower_value");
const iteration_entry = @import("generated_lower_iteration");
const binary_entry = @import("generated_lower_binary");

pub const Api = @import("execution_abi").layouts.@"zig:lowering_host";

pub inline fn borrow(frame: *anyopaque) *Lower {
    return @ptrCast(@alignCast(frame));
}

pub fn regular(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(regular_entry.Input);
    const Store = std.meta.Child(@FieldType(Input, "store"));
    const Expressions = std.meta.Child(@FieldType(Input, "expressions"));
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const row = @backingInt(id);
    const table: *const ir.ExpressionTable = &self.program.expressions;
    const expressions = zx.columns.borrow(Expressions, table);
    const types = ir.TypeTable.borrow(Types, self.program.types);

    const store: Store = .{
        .queries = zx.columns.slice(@FieldType(Store, "queries"), self.state_plan.queries),
        .active = self.state_active,
        .count = self.program.stores.count(),
        .mode = switch (self.program.store_mode) {
            .transaction => .transaction,
            .orchestration => .orchestration,
        },
    };

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .store = &store,
        .expressions = &expressions,
        .types = &types,
        .id = row,
        .kind = @fromBackingInt(@backingInt(table.kinds[row])),
        .type_id = table.types[row],
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = regular_entry.executeIn(memory.allocator(), &input) catch |err| return executionFailure(err);

    self.uses_context = self.uses_context or output.uses_context;

    return @fromBackingInt(output.expression);
}

pub fn value(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(value_entry.Input);
    const Expressions = std.meta.Child(@FieldType(Input, "expressions"));
    const expressions = zx.columns.borrow(Expressions, @as(*const ir.ExpressionTable, &self.program.expressions));
    const plan = @import("../value_call/policy.zig").dispatch(self, id);

    comptime view.compatible(@TypeOf(plan.route), @FieldType(Input, "route"));

    const probe: std.meta.Child(@FieldType(Input, "probe")) = .{ .checked = plan.probe.checked, .value = plan.probe.value };

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .expressions = &expressions,
        .id = @backingInt(id),
        .route = @fromBackingInt(@backingInt(plan.route)),
        .probe = &probe,
    };

    return invokeWith(self, value_entry, &input);
}

pub fn iteration(self: *Iteration, id: ir.ExprId, plan: anytype) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(iteration_entry.Input);
    const Expressions = std.meta.Child(@FieldType(Input, "expressions"));
    const expressions = zx.columns.borrow(Expressions, @as(*const ir.ExpressionTable, &self.lowering.program.expressions));

    comptime view.compatible(@TypeOf(plan.route), @FieldType(Input, "route"));

    const probe: std.meta.Child(@FieldType(Input, "probe")) = .{ .checked = plan.probe.checked, .value = plan.probe.value };

    const input: Input = .{
        .frame = @ptrCast(self.lowering),
        .writer = @ptrCast(self.lowering),
        .expressions = &expressions,
        .id = @backingInt(id),
        .route = @fromBackingInt(@backingInt(plan.route)),
        .probe = &probe,
        .value = plan.value,
        .value_call = plan.value_call,
        .argument = if (self.argument) |argument| @backingInt(argument.value) else null,
    };

    return invokeWith(self.lowering, iteration_entry, &input);
}

pub fn binary(self: *Lower, term: @FieldType(@FieldType(ir.ExpressionRow, "value"), "binary")) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(binary_entry.Input);
    const Expressions = std.meta.Child(@FieldType(Input, "expressions"));
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const expressions = zx.columns.borrow(Expressions, @as(*const ir.ExpressionTable, &self.program.expressions));
    const types = ir.TypeTable.borrow(Types, self.program.types);

    comptime view.compatible(@TypeOf(term.operator), @FieldType(Input, "operator"));

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .expressions = &expressions,
        .types = &types,
        .operator = @fromBackingInt(@intCast(@backingInt(term.operator))),
        .left_ir = @backingInt(term.left),
        .right_ir = @backingInt(term.right),
    };

    return invokeWith(self, binary_entry, &input);
}

pub fn invoke(comptime entry: type, input: entry.Input) Lower.Error!node.ExpressionId {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return @fromBackingInt(entry.executeIn(empty.allocator(), input) catch |err| return executionFailure(err));
}

pub fn invokeWith(self: *Lower, comptime entry: type, input: entry.Input) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    return @fromBackingInt(entry.executeIn(memory.allocator(), input) catch |err| return executionFailure(err));
}

pub fn invokeOptional(comptime entry: type, input: entry.Input) Lower.Error!?node.ExpressionId {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const output = entry.executeIn(empty.allocator(), input) catch |err| return executionFailure(err);

    return if (output) |id| @fromBackingInt(id) else null;
}

pub fn execute(comptime entry: type, input: entry.Input) Lower.Error!void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(empty.allocator(), input) catch |err| return executionFailure(err);
}

pub fn executeWith(self: *Lower, comptime entry: type, input: entry.Input) Lower.Error!void {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();
    entry.executeIn(memory.allocator(), input) catch |err| return executionFailure(err);
}

fn executionFailure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
        else => unreachable,
    };
}
