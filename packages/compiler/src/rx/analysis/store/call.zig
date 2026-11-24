const std = @import("std");
const frontend = @import("frontend");
const syntax = @import("zx").syntax.borrow;
const Store = @import("../store.zig");
const getters = @import("getters.zig");
const access = @import("access.zig");
const Scope = @import("references.zig").Scope;
const generated = @import("rx_options").generated_graph;

pub fn reads(allocator: std.mem.Allocator, backing: std.mem.Allocator, parsed: *const frontend.ExpressionInput.Result, scope: Scope) std.mem.Allocator.Error![]const Store.Binding {
    if (scope.names.len == 0) return &.{};

    return switch (parsed.*) {
        .native => |result| if (generated) &.{} else collectReads(allocator, result.value.parsed.expression, scope),
        .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) access.reads(allocator, backing, result, scope) else unreachable,
    };
}

pub fn setter(backing: std.mem.Allocator, parsed: *const frontend.ExpressionInput.Result, scope: Scope) std.mem.Allocator.Error!access.Setter {
    return switch (parsed.*) {
        .native => |result| if (generated) invalidSetterList() else selectSetter(result.value.parsed.expression, scope),
        .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) access.setter(backing, result, scope) else unreachable,
    };
}

fn collectReads(allocator: std.mem.Allocator, expression: anytype, scope: Scope) std.mem.Allocator.Error![]const Store.Binding {
    var bindings: std.ArrayList(Store.Binding) = .empty;

    for (scope.names, 0..) |name, index| if (getters.contains(expression, name)) {
        try bindings.append(allocator, scope.at(index));
    };

    return bindings.items;
}

const SetterResult = access.Setter;

fn selectSetter(expression: anytype, scope: Scope) SetterResult {
    const value = syntax.value(expression);

    if (value != .list or value.list.len != 1) return invalidSetterList();

    const path = syntax.item(value.list, 0);

    for (scope.names, 0..) |name, index| if (getters.matches(path, name)) {
        return selectedSetter(scope.at(index));
    };

    return missingSetter(path.span.start);
}

fn selectedSetter(binding: Store.Binding) SetterResult {
    return .{ .setter = .{ .name = binding.name, .path = binding.path, .type_id = binding.type_id } };
}

fn invalidSetterList() SetterResult {
    return .{ .invalid = .{ .offset = 0, .message = "Call.setter must list exactly one complete Store Object" } };
}

fn missingSetter(offset: usize) SetterResult {
    return .{ .invalid = .{ .offset = offset, .message = "Call.setter must reference a complete Object declared by this module" } };
}
