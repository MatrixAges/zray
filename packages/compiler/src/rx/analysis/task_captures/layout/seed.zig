const std = @import("std");
const ir = @import("zx").ir;
const Bindings = @import("frontend").expressions.BindingColumns;
const Layout = @import("../layout.zig");

pub fn plan(allocator: std.mem.Allocator, types: []const ir.TypeId, positions: []const u32, parameters: []const ir.TypeId) std.mem.Allocator.Error!Layout {
    const source_types = try allocator.alloc(ir.TypeId, positions.len);
    const parameter_types = try allocator.alloc(ir.TypeId, positions.len);
    const elements = try allocator.alloc(ir.ExprId, positions.len);
    var cursor = 1 + positions.len;
    var optional_count: usize = 0;

    for (positions, source_types, parameter_types, elements) |position, *source, *parameter, *element| {
        source.* = types[position];
        parameter.* = parameters[position];
        const narrowed = source.* != parameter.*;

        cursor += if (narrowed) @as(usize, 2) else 1;
        element.* = @fromBackingInt(@intCast(cursor - 1));
        optional_count += @intFromBool(narrowed);
    }

    return .{ .positions = positions, .source_types = source_types, .parameter_types = parameter_types, .elements = elements, .optional_count = optional_count };
}

pub fn narrow(types: ir.TypeTable, bindings: Bindings, facts: []const []const u8, output: []ir.TypeId) void {
    for (bindings.names, bindings.types, output) |binding, type_id, *target| {
        const value = types.at(@backingInt(type_id));

        target.* = type_id;

        if (value != .optional) continue;

        for (facts) |name| {
            if (!std.mem.eql(u8, name, binding)) continue;

            target.* = value.optional;

            break;
        }
    }
}
