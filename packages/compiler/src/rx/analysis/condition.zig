const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const generated = @import("rx_options").generated_graph;
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

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const rule = @import("generated_rx_condition_walk");

    const outcome = rule.executeIn(scratch.allocator(), &.{
        .source = source,
        .nodes = zx.columns.slice(@FieldType(std.meta.Child(rule.Input), "nodes"), nodes),
        .names = scope.bindings,
        .implicit_input = scope.implicit_input,
        .condition = index,
        .truth = present,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    for (outcome.borrowed) |view| try scope.facts.append(scope.allocator, view);
    for (outcome.rendered) |item| try scope.publish(try frontend.binding_path.renderIndexed(scope.allocator, source, nodes, item.node, item.length));
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
