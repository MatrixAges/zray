const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const generated = @import("rx_options").generated_graph;
const inline_pending = 16;
pub const Cases = @import("condition/cases.zig");

pub const Scope = struct {
    allocator: std.mem.Allocator,
    bindings: []const []const u8,
    implicit_input: bool = false,
    facts: *std.ArrayList([]const u8),
    fn publish(self: Scope, path: frontend.binding_path.Path) std.mem.Allocator.Error!void {
        var retained = false;

        defer if (!retained) path.release(self.allocator);

        if (!@import("inference/scope.zig").rooted(self.bindings, path, self.implicit_input)) return;
        try self.facts.append(self.allocator, path.text);

        retained = true;
    }
};

pub fn boolean(parsed: *const frontend.ExpressionInput.Result) ?bool {
    if (parsed.diagnostic() != null) return null;

    return switch (parsed.*) {
        .native => |result| if (result.value.parsed.expression.value == .boolean) result.value.parsed.expression.value.boolean else null,
        .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) block: {
            const node = result.output.expressions.nodes[@intCast(result.output.result)];

            break :block if (node.kind == .Boolean) node.flag else null;
        } else unreachable,
    };
}

pub fn assumeParsed(allocator: std.mem.Allocator, parsed: *const frontend.ExpressionInput.Result, present: bool, scope: Scope) zx.Error!void {
    switch (parsed.*) {
        .native => |result| try assumeNative(result.value.parsed.expression, present, scope),
        .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) {
            if (comptime generated) return assumeIndexed(allocator, result.source, result.output.expressions.nodes, result.output.result, present, scope);

            var scratch = std.heap.ArenaAllocator.init(allocator);

            defer scratch.deinit();

            const view = try result.view(scratch.allocator());

            try assumeValue(scratch.allocator(), view.expression(result.output.result), present, scope);
        } else unreachable,
    }
}

pub fn assumeValue(allocator: std.mem.Allocator, expression: anytype, present: bool, scope: Scope) zx.Error!void {
    if (comptime !generated or @TypeOf(expression) == *const zx.ast.Expression) return assumeNative(expression, present, scope);

    const context = expression.context;

    return assumeIndexed(allocator, context.source, context.storage.expressions.nodes, expression.index, present, scope);
}

fn assumeIndexed(allocator: std.mem.Allocator, source: []const u8, nodes: frontend.binding_path.IndexedNodes, index: u64, present: bool, scope: Scope) zx.Error!void {
    const node = nodes[@intCast(index)];

    if (node.kind != .Binary and node.kind != .Unary) return;
    if (scope.bindings.len == 0 and !scope.implicit_input) return;

    var inline_stack: [inline_pending]u64 = undefined;
    const limit: usize = @intCast(node.depth);
    const pending = if (limit <= inline_stack.len) inline_stack[0..limit] else try allocator.alloc(u64, limit);

    defer if (limit > inline_stack.len) allocator.free(pending);

    const rule = @import("generated_rx_condition_plan");
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var current = index;
    var truth = present;
    var depth: u64 = 0;

    while (true) {
        const tail = scope.facts.unusedCapacitySlice();

        const input: std.meta.Child(rule.Input) = .{
            .source = source,
            .nodes = nodes,
            .names = scope.bindings,
            .implicit_input = scope.implicit_input,
            .target = @ptrCast(&tail),
            .capacity = tail.len,
            .pending = @ptrCast(&pending),
            .condition = current,
            .truth = truth,
            .depth = depth,
            .active = true,
        };

        const step = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        scope.facts.items.len += @intCast(step.written);

        switch (step.action) {
            .Scan => return,
            .Borrow => try scope.facts.append(scope.allocator, source[@intCast(step.start)..][0..@intCast(step.length)]),
            .Render => try scope.publish(try frontend.binding_path.renderIndexed(scope.allocator, source, nodes, step.node, step.length)),
        }

        if (!step.active) return;

        current = step.condition;
        truth = step.truth;
        depth = step.depth;
    }
}

fn assumeNative(expression: anytype, present: bool, scope: Scope) zx.Error!void {
    const value = syntax.value(expression);

    if (value == .unary and value.unary.operator == .not) return assumeNative(value.unary.operand, !present, scope);
    if (value != .binary) return;

    const binary = value.binary;

    if ((binary.operator == .logical_and and present) or (binary.operator == .logical_or and !present)) {
        try assumeNative(binary.left, present, scope);
        try assumeNative(binary.right, present, scope);

        return;
    }

    if (binary.operator != .equal and binary.operator != .not_equal) return;
    if ((binary.operator == .not_equal) != present) return;

    const expression_value = if (syntax.value(binary.left) == .null_value)
        binary.right

    else if (syntax.value(binary.right) == .null_value)
        binary.left
    else
        return;

    if (try frontend.binding_path.view(scope.allocator, expression_value)) |path| try scope.publish(path);
}
