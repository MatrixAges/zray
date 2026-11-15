const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Bindings = frontend.expressions.BindingColumns;
const Result = frontend.ExpressionInput.Result;
const generated = @import("rx_options").generated_graph;

pub const Selection = struct {
    bindings: Bindings,
    positions: ?[]const u32 = null,
};

pub fn select(allocator: std.mem.Allocator, parsed: *const Result, bindings: Bindings, facts: []const []const u8) std.mem.Allocator.Error!Selection {
    const names = bindings.names;

    if (names.len < 2 or parsed.diagnostic() != null) return .{ .bindings = bindings };

    const positions = switch (parsed.*) {
        .native => |result| try native(allocator, result.value.parsed.expression, names, facts),
        .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) block: {
            if (comptime generated) return indexed(allocator, result, bindings, facts);

            const view = try result.view(allocator);

            break :block try indexSeed(allocator, view, names, facts);
        } else unreachable,
    };

    if (positions.len == names.len) return .{ .bindings = bindings };

    const selected_names = try allocator.alloc([]const u8, positions.len);
    const selected_types = try allocator.alloc(zx.ir.TypeId, positions.len);

    for (positions, selected_names, selected_types) |index, *name, *type_id| {
        name.* = names[index];
        type_id.* = bindings.types[index];
    }

    return .{ .bindings = .{ .names = selected_names, .types = selected_types }, .positions = positions };
}

fn indexed(allocator: std.mem.Allocator, input: frontend.ExpressionInput.Indexed, bindings: Bindings, facts: []const []const u8) std.mem.Allocator.Error!Selection {
    const rule = @import("generated_rx_expression_scope");

    const request: std.meta.Child(rule.Input) = .{
        .source = input.source,
        .nodes = input.output.expressions.nodes,
        .names = bindings.names,
        .types = @ptrCast(bindings.types),
        .facts = facts,
    };

    const selected = zx.columns.invoke(rule.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .bindings = .{ .names = selected.names, .types = @ptrCast(selected.types) }, .positions = selected.positions };
}

fn native(allocator: std.mem.Allocator, expression: *const zx.ast.Expression, names: []const []const u8, facts: []const []const u8) std.mem.Allocator.Error![]const u32 {
    var selected: std.ArrayList(u32) = .empty;

    for (names, 0..) |name, index| {
        if (@import("expression_scope/seed.zig").includes(expression, facts, name)) try selected.append(allocator, @intCast(index));
    }

    return selected.items;
}

fn indexSeed(allocator: std.mem.Allocator, view: frontend.ExpressionInput.View, names: []const []const u8, facts: []const []const u8) std.mem.Allocator.Error![]const u32 {
    var selected: std.ArrayList(u32) = .empty;
    const paths = frontend.binding_path;

    for (names, 0..) |name, index| {
        const found = for (0..view.storage.expressions.nodes.len) |node| {
            if (paths.matches(view.expression(node), name)) break true;
        } else for (facts) |fact| {
            if (name.len <= fact.len and paths.overlaps(name, fact)) break true;
        } else false;

        if (found) try selected.append(allocator, @intCast(index));
    }

    return selected.items;
}
