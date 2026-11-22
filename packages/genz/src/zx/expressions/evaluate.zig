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

pub inline fn borrow(frame: *const anyopaque) *Lower {
    return @ptrCast(@alignCast(@constCast(frame)));
}

pub fn regular(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(regular_entry.Input);
    const row = @backingInt(id);
    const table = &self.program.expressions;

    const input: Input = .{
        .frame = @ptrCast(self),
        .id = row,
        .kind = @fromBackingInt(@backingInt(table.kinds[row])),
        .type_id = table.types[row],
    };

    return invoke(regular_entry, &input);
}

pub fn value(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(value_entry.Input);
    const plan = @import("../value_call/policy.zig").dispatch(self, id);

    comptime view.compatible(@TypeOf(plan.route), @FieldType(Input, "route"));

    const probe: std.meta.Child(@FieldType(Input, "probe")) = .{ .checked = plan.probe.checked, .value = plan.probe.value };

    const input: Input = .{
        .frame = @ptrCast(self),
        .id = @backingInt(id),
        .route = @fromBackingInt(@backingInt(plan.route)),
        .probe = &probe,
    };

    return invoke(value_entry, &input);
}

pub fn iteration(self: *Iteration, id: ir.ExprId, plan: anytype) Lower.Error!node.ExpressionId {
    const Input = std.meta.Child(iteration_entry.Input);

    comptime view.compatible(@TypeOf(plan.route), @FieldType(Input, "route"));

    const probe: std.meta.Child(@FieldType(Input, "probe")) = .{ .checked = plan.probe.checked, .value = plan.probe.value };

    const input: Input = .{
        .frame = @ptrCast(self.lowering),
        .id = @backingInt(id),
        .route = @fromBackingInt(@backingInt(plan.route)),
        .probe = &probe,
        .value = plan.value,
        .value_call = plan.value_call,
        .argument = if (self.argument) |argument| @backingInt(argument.value) else null,
    };

    return invoke(iteration_entry, &input);
}

pub fn binary(self: *Lower, term: @FieldType(@FieldType(ir.ExpressionRow, "value"), "binary")) Lower.Error!node.ExpressionId {
    const input: std.meta.Child(binary_entry.Input) = .{
        .frame = @ptrCast(self),
        .operator = @backingInt(term.operator),
        .left_ir = @backingInt(term.left),
        .right_ir = @backingInt(term.right),
    };

    return invoke(binary_entry, &input);
}

pub fn invoke(comptime entry: type, input: entry.Input) Lower.Error!node.ExpressionId {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return @fromBackingInt(entry.executeIn(empty.allocator(), input) catch |err| return executionFailure(err));
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

fn executionFailure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
        else => unreachable,
    };
}
