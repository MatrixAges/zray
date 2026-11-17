const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Binding = @import("../../function_import.zig");
const Nodes = @import("../../artifact/nodes.zig");
const Error = @import("../program.zig").Error;
const Result = struct { members: []const Binding, entry: ?ir.FunctionId };
const Member = struct { binding: Binding, entry: bool };

pub fn link(nodes: *Nodes, source: []const Binding, entry: ?ir.FunctionId) Error!Result {
    if (source.len == 0) return .{ .members = &.{}, .entry = entry };

    var members: std.ArrayList(Binding) = .empty;
    var function = entry;

    for (source) |item| {
        const member = try seed(nodes, item);

        if (member.entry) {
            if (function != null) return error.InvalidModule;

            function = member.binding.id;
        } else try members.append(nodes.allocator, member.binding);
    }

    return .{ .members = members.items, .entry = function };
}

fn seed(nodes: *Nodes, item: Binding) Error!Member {
    var member = item;

    member.id = if (item.id) |id| try nodes.functionId(id) else null;
    member.input_type = if (item.input_type) |id| try nodes.types.include(id) else null;
    member.output_type = if (item.output_type) |id| try nodes.types.include(id) else null;
    member.name = try nodes.allocator.dupe(u8, item.name);
    member.namespace = null;

    return .{ .binding = member, .entry = member.name.len == 0 and member.intrinsic == null };
}
