const std = @import("std");
const rx = @import("rx");
const frontend = @import("frontend");
const syntax = @import("zx").syntax.borrow;
const Store = @import("../store.zig");
const target = @import("../call/target.zig");
const getters = @import("getters.zig");
const access = @import("access.zig");
const Scope = @import("references.zig").Scope;
const generated = @import("rx_options").generated_graph;

pub const Authorization = struct { getters: []const Store.Binding, setter: ?target.Setter = null };
pub const Value = union(enum) { authorized: Authorization, diagnostic: target.Diagnostic };

pub fn analyze(allocator: std.mem.Allocator, backing: std.mem.Allocator, owner: []const u8, attributes: @import("../call/attributes.zig"), scope: Scope, argument: ?*const frontend.ExpressionInput.Result) std.mem.Allocator.Error!Value {
    var reads: std.ArrayList(Store.Binding) = .empty;

    if (attributes.argument) |input| {
        const parsed = argument.?;

        if (parsed.diagnostic()) |issue| {
            return failure(allocator, owner, input.*, issue.span.start, @tagName(issue.code), issue.message);
        }

        if (scope.names.len != 0) switch (parsed.*) {
            .native => |result| try collectReads(allocator, &reads, result.value.parsed.expression, scope),
            .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) indexed: {
                if (comptime generated) {
                    reads = .fromOwnedSlice(try access.reads(allocator, backing, result, scope));

                    break :indexed;
                }

                var scratch = std.heap.ArenaAllocator.init(backing);

                defer scratch.deinit();

                const view = try result.view(scratch.allocator());

                try collectReads(allocator, &reads, view.expression(result.output.result), scope);
            } else unreachable,
        };
    }

    var setter: ?target.Setter = null;

    if (attributes.setter) |item| {
        const attribute = item.*;
        var writes = try @import("../attribute.zig").parseBorrowed(backing, attribute, owner);

        defer writes.deinit();

        if (writes.diagnostic()) |issue| {
            return failure(allocator, owner, attribute, issue.span.start, @tagName(issue.code), issue.message);
        }

        const selected = switch (writes) {
            .native => |result| selectSetter(result.value.parsed.expression, scope),
            .indexed => |result| if (frontend.ExpressionInput.indexed_enabled) block: {
                if (comptime generated) {
                    break :block try access.setter(backing, result, scope);
                }

                var scratch = std.heap.ArenaAllocator.init(backing);

                defer scratch.deinit();

                const view = try result.view(scratch.allocator());

                break :block selectSetter(view.expression(result.output.result), scope);
            } else unreachable,
        };

        switch (selected) {
            .setter => |value| setter = value,
            .invalid => |issue| return failure(allocator, owner, attribute, issue.offset, "capability", issue.message),
        }
    }

    return .{ .authorized = .{ .getters = reads.items, .setter = setter } };
}

fn collectReads(allocator: std.mem.Allocator, reads: *std.ArrayList(Store.Binding), expression: anytype, scope: Scope) std.mem.Allocator.Error!void {
    for (scope.names, 0..) |name, index| if (getters.contains(expression, name)) {
        try reads.append(allocator, scope.at(index));
    };
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

fn failure(allocator: std.mem.Allocator, owner: []const u8, attribute: rx.ast.Attribute, offset: usize, code: []const u8, message: []const u8) std.mem.Allocator.Error!Value {
    const failed = try target.failure(allocator, .{ .path = owner, .location = rx.attributeLocation(attribute, offset) orelse attribute.value_location, .code = code, .message = message });

    return .{ .diagnostic = failed.diagnostic };
}
