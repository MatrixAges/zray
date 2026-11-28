const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Scope = @import("scope.zig");
const Selection = @import("../switch/state.zig");
const rows = @import("../../construction/publication.zig");
const entry = @import("generated_statement_traversal");
const execute = @import("generated_execute_statement_traversal");
const Input = std.meta.Child(entry.Input);
const Rows = std.meta.Child(@FieldType(Input, "rows"));
const Api = @import("../../expressions/evaluate.zig").Api;
const StatementStack = Api.StatementStack;

pub const Frame = struct {
    lowering: *Lower,
    control: @FieldType(ir.Block, "control"),
    spans: []u64,
    scopes: []Scope,
    selections: []Selection,
    sequence: @import("../../../node/blocks.zig").Sequence,
    child: node.Block = .{},
    stack_view: StatementStack = undefined,
    pub fn borrow(handle: *const anyopaque) *Frame {
        const reference: *const *Frame = @ptrCast(@alignCast(handle));

        return reference.*;
    }
    pub fn block(self: *const Frame, slot: u64) ir.Block {
        return self.scopes[@intCast(slot)].values;
    }
};

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var inline_memory: [4096]u8 = undefined;
    var buffer = std.heap.BufferFirstAllocator.init(&inline_memory, arena.allocator());

    defer arena.deinit();

    const scratch = buffer.allocator();
    const control_source: *const zx.ir.ControlTable = values.control;
    const row_inputs = zx.columns.borrow(Rows, control_source);
    const input: Input = .{ .rows = &row_inputs, .first = values.first, .count = values.len };
    const plan = zx.columns.invoke(entry.executeValue, scratch, &input) catch |err| return failure(err);
    const capacity: usize = @intCast(plan.capacity);
    const depth: usize = @intCast(plan.depth);
    const spans = try scratch.alloc(u64, capacity);
    const selection_depth: usize = if (plan.flat) 0 else @intCast(plan.selection_depth);
    var flat_scope: [1]Scope = undefined;
    const scopes: []Scope = if (plan.flat) &flat_scope else try scratch.alloc(Scope, depth);
    const selections: []Selection = if (plan.flat) &.{} else try scratch.alloc(Selection, selection_depth);

    for (scopes) |*scope| scope.active = false;
    for (selections) |*selection| selection.active = false;

    var frame: Frame = .{
        .lowering = self,
        .control = values.control,
        .spans = spans,
        .scopes = scopes,
        .selections = selections,
        .sequence = self.builder.statementSequence(self.workspace),
    };

    defer frame.sequence.deinit();

    defer {
        var index = selections.len;

        while (index != 0) {
            index -= 1;

            selections[index].leave(self);
        }

        index = scopes.len;

        while (index != 0) {
            index -= 1;

            scopes[index].close(self);
        }
    }

    const Execution = std.meta.Child(execute.Input);
    const Schedule = std.meta.Child(@FieldType(Execution, "plan"));
    const Context = std.meta.Child(@FieldType(Execution, "context"));
    const Control = std.meta.Child(@FieldType(Context, "control"));
    const Expressions = std.meta.Child(@FieldType(Context, "expressions"));
    const Types = std.meta.Child(@FieldType(Context, "types"));
    const control = zx.columns.borrow(Control, control_source);
    const expressions = zx.columns.borrow(Expressions, @as(*const ir.ExpressionTable, &self.program.expressions));
    const types = ir.TypeTable.borrow(Types, self.program.types);
    const schedule = zx.columns.view(Schedule, plan);
    const reference = &frame;

    const context: Context = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(&frame.sequence),
        .control = &control,
        .expressions = &expressions,
        .types = &types,
        .output_type = @backingInt(self.program.output_type),
        .store_mode = @fromBackingInt(@backingInt(self.program.store_mode)),
        .store_count = self.program.stores.count(),
        .names = self.names,
        .used = self.used,
        .transaction = self.transaction(),
        .value_output = self.value_output,
        .state_active = self.state_active,
        .public_value_output = self.public_value_output,
    };

    const request: Execution = .{
        .traversal = @ptrCast(&reference),
        .context = &context,
        .plan = &schedule,
        .first = @intCast(values.first),
        .count = @intCast(values.len),
    };

    const valid = execute.executeIn(scratch, &request) catch |err| return failure(err);

    if (!valid) return error.OutOfMemory;

    return frame.child;
}

pub fn openStatementScope(handle: *const anyopaque, slot: u64, first: u32, count: u32, placement: u64) ?*const StatementStack {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];
    const start: usize = @intCast(placement);
    const range: ir.Block = .{ .control = frame.control, .first = first, .len = count };
    scope.* = Scope.open(frame.lowering, range, frame.spans[start..][0..count]) catch return null;
    const stack = frame.lowering.stack_symbols.current();
    frame.stack_view = .{ .stack_keys = stack.keys.items, .stack_buckets = stack.buckets.items };

    return &frame.stack_view;
}

pub fn finishStatementScope(handle: *const anyopaque, slot: u64, writes: []const *const Api.StatementWrite) ?u64 {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];

    for (writes) |write| {
        scope.put(@intCast(write.row), .{ .start = write.start, .len = write.count });

        if (write.previous) |index| scope.put(@intCast(index), .{});
    }

    frame.child = scope.finish(frame.lowering) catch return null;

    scope.close(frame.lowering);

    return rows.packSpan(frame.child);
}

pub fn openStatementSelection(handle: *const anyopaque, slot: u64, offset: u32, placement: u64, name: []const u8, subject: u32, reference: u32) bool {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];

    frame.selections[@intCast(placement)].enter(
        frame.lowering,
        scope.values.at(offset).switch_stmt,
        name,
        @fromBackingInt(subject),
        @fromBackingInt(reference),
    ) catch return false;

    return true;
}

pub fn resolveStatementSelection(handle: *const anyopaque, placement: u64, count: u32, selected: bool) bool {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].resolve(count, selected) catch return false;

    return true;
}

pub fn saveStatementCase(handle: *const anyopaque, placement: u64, index: u32, comparison: u32, literal: ?u32) void {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].saveCase(index, frame.child, comparison, literal);
}

pub fn finishStatementSelection(handle: *const anyopaque, slot: u64, offset: u32, placement: u64, fallback: ?u64) bool {
    const frame = Frame.borrow(handle);
    const selection = &frame.selections[@intCast(placement)];
    selection.fallback = if (fallback) |value| rows.unpackSpan(value) else null;

    const block = selection.finish(frame.lowering) catch return false;

    frame.scopes[@intCast(slot)].put(offset, block);
    selection.leave(frame.lowering);

    return true;
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
