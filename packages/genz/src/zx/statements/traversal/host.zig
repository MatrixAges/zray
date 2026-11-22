const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Scope = @import("scope.zig");
const Selection = @import("../switch/state.zig");
const basic = @import("../basic.zig");
const entry = @import("generated_statement_traversal");
const execute = @import("generated_execute_statement_traversal");
const Input = std.meta.Child(entry.Input);
const Rows = std.meta.Child(@FieldType(Input, "rows"));

pub const Frame = struct {
    lowering: *Lower,
    control: @FieldType(ir.Block, "control"),
    workspace: Scope.Buffer,
    scopes: []Scope,
    selections: []Selection,
    output: std.ArrayList(node.Statement) = .empty,
    sequence: @import("../../../node/blocks.zig").Sequence,
    prefix: node.Block = undefined,
    body: node.Block = undefined,
    consumed_previous: bool = undefined,
    binding: @FieldType(ir.StatementRow, "constant") = undefined,
    borrowed: ?node.ExpressionId = null,
    child: node.Block = .{},
    pub fn borrow(handle: *const anyopaque) *Frame {
        const reference: *const *Frame = @ptrCast(@alignCast(handle));

        return reference.*;
    }
    pub fn block(self: *const Frame, slot: u64) ir.Block {
        return self.scopes[@intCast(slot)].values;
    }

    pub fn emitted(self: *Frame, span: node.Block, consumed_previous: bool) bool {
        self.body = span;
        self.consumed_previous = consumed_previous;

        return true;
    }
};

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var inline_memory: [4096]u8 = undefined;
    var buffer = std.heap.BufferFirstAllocator.init(&inline_memory, arena.allocator());

    defer arena.deinit();

    const scratch = buffer.allocator();
    const rows = zx.columns.borrow(Rows, values.control);
    const input: Input = .{ .rows = &rows, .first = values.first, .count = values.len };
    const plan = zx.columns.invoke(entry.executeValue, scratch, &input) catch |err| return failure(err);
    const capacity: usize = @intCast(plan.capacity);
    const spans = try scratch.alloc(u32, std.math.mul(usize, capacity, 2) catch return error.OutOfMemory);
    const routes = try scratch.alloc(u8, capacity);
    var flat_scope: [1]Scope = undefined;

    var frame: Frame = .{
        .lowering = self,
        .control = values.control,
        .workspace = .{
            .starts = spans[0..capacity],
            .counts = spans[capacity..],
            .routes = routes,
        },
        .scopes = if (plan.flat) &flat_scope else try scratch.alloc(Scope, @intCast(plan.depth)),
        .selections = if (plan.flat) &.{} else try scratch.alloc(Selection, @intCast(plan.selection_depth)),
        .sequence = self.builder.statementSequence(self.workspace),
    };

    defer frame.output.deinit(self.allocator);
    defer frame.sequence.deinit();

    const Execution = std.meta.Child(execute.Input);
    const Schedule = std.meta.Child(@FieldType(Execution, "plan"));
    const schedule = zx.columns.view(Schedule, plan);
    const reference = &frame;

    const request: Execution = .{
        .traversal = @ptrCast(&reference),
        .plan = &schedule,
        .first = @intCast(values.first),
        .count = @intCast(values.len),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const valid = execute.executeIn(fixed.allocator(), &request) catch |err| return failure(err);

    if (!valid) return error.OutOfMemory;

    return frame.child;
}

pub fn openStatementScope(handle: *const anyopaque, slot: u64, first: u32, count: u32, placement: u64) bool {
    const frame = Frame.borrow(handle);
    const workspace = frame.workspace;
    const scope = &frame.scopes[@intCast(slot)];
    const start: usize = @intCast(placement);
    const range: ir.Block = .{ .control = frame.control, .first = first, .len = count };

    scope.* = Scope.open(frame.lowering, range, .{
        .starts = workspace.starts[start..][0..count],
        .counts = workspace.counts[start..][0..count],
        .routes = workspace.routes[start..][0..count],
    }) catch return false;

    return true;
}

pub fn statementRoute(handle: *const anyopaque, slot: u64, index: u64) u8 {
    return Frame.borrow(handle).scopes[@intCast(slot)].routes[@intCast(index)];
}

pub fn commitStatementSpan(handle: *const anyopaque, slot: u64, cursor: u64) u64 {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];

    return scope.publish(@intCast(cursor), frame.body, frame.consumed_previous);
}

pub fn finishStatementScope(handle: *const anyopaque, slot: u64) bool {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];

    frame.child = scope.finish(frame.lowering) catch return false;

    scope.close(frame.lowering);

    return true;
}

pub fn releaseStatementScope(handle: *const anyopaque, slot: u64) void {
    const frame = Frame.borrow(handle);

    frame.scopes[@intCast(slot)].close(frame.lowering);
}

pub fn lowerStatementCondition(handle: *const anyopaque, slot: u64, offset: u32) bool {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];
    scope.condition = frame.lowering.expr(scope.values.at(offset).branch.condition) catch return false;

    return true;
}

pub fn saveStatementBranch(handle: *const anyopaque, slot: u64) bool {
    const frame = Frame.borrow(handle);

    frame.scopes[@intCast(slot)].yes = frame.child;

    return true;
}

pub fn joinStatementBranch(handle: *const anyopaque, slot: u64, offset: u32) bool {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];

    frame.output.clearRetainingCapacity();

    const branch = basic.branch(frame.lowering, &frame.output, scope.condition, scope.yes, frame.child) catch return false;

    scope.put(offset, branch);

    return true;
}

pub fn openStatementSelection(handle: *const anyopaque, slot: u64, offset: u32, placement: u64) bool {
    const frame = Frame.borrow(handle);
    const scope = &frame.scopes[@intCast(slot)];

    frame.selections[@intCast(placement)].enter(frame.lowering, scope.values.at(offset).switch_stmt) catch return false;

    return true;
}

pub fn saveStatementFallback(handle: *const anyopaque, placement: u64) bool {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].fallback = frame.child;

    return true;
}

pub fn resolveStatementSelection(handle: *const anyopaque, placement: u64, count: u32) bool {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].resolve(frame.lowering, count) catch return false;

    return true;
}

pub fn statementSelectionUsesSwitch(handle: *const anyopaque, placement: u64) bool {
    return Frame.borrow(handle).selections[@intCast(placement)].selected;
}

pub fn statementSelectionCaseCount(handle: *const anyopaque, placement: u64) u64 {
    return Frame.borrow(handle).selections[@intCast(placement)].starts.len;
}

pub fn resetStatementCase(handle: *const anyopaque, placement: u64, index: u32) void {
    Frame.borrow(handle).selections[@intCast(placement)].resetCase(index);
}

pub fn saveStatementCase(handle: *const anyopaque, placement: u64, index: u32) void {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].saveCase(index, frame.child);
}

pub fn lowerStatementComparison(handle: *const anyopaque, placement: u64, index: u32, label: u32) bool {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].compareCase(frame.lowering, index, @fromBackingInt(label)) catch return false;

    return true;
}

pub fn lowerStatementCaseLiteral(handle: *const anyopaque, placement: u64, index: u32, label: u32) bool {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].literalCase(frame.lowering, index, @fromBackingInt(label)) catch return false;

    return true;
}

pub fn finishStatementSelection(handle: *const anyopaque, slot: u64, offset: u32, placement: u64) bool {
    const frame = Frame.borrow(handle);
    const selection = &frame.selections[@intCast(placement)];
    const block = selection.finish(frame.lowering) catch return false;

    frame.scopes[@intCast(slot)].put(offset, block);
    selection.leave(frame.lowering);

    return true;
}

pub fn releaseStatementSelection(handle: *const anyopaque, placement: u64) void {
    const frame = Frame.borrow(handle);

    frame.selections[@intCast(placement)].leave(frame.lowering);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
