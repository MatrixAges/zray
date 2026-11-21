const std = @import("std");
const zx = @import("zx");
const State = @import("../state.zig");
const generated = @import("rx_options").generated_graph;
const Boundary = struct { functions: usize, types: usize };
const Plan = struct { replace_prefix: bool, type_prefix: ?usize };

pub fn prepare(state: *const State, prepared: Boundary, body_functions: usize) Plan {
    const current: Boundary = .{
        .functions = state.functions.count(),
        .types = state.types.items.count(),
    };

    if (comptime generated) {
        const rule = @import("generated_rx_mixed_body_link");

        const input: std.meta.Child(rule.Input) = .{
            .prepared = &.{ .functions = prepared.functions, .types = prepared.types },
            .current = &.{ .functions = current.functions, .types = current.types },
            .body_functions = body_functions,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{
            .replace_prefix = result.replace_prefix,
            .type_prefix = if (result.type_prefix) |count| @intCast(count) else null,
        };
    }

    return .{
        .replace_prefix = body_functions == prepared.functions,
        .type_prefix = if (current.functions == prepared.functions and current.types == prepared.types) null else prepared.types,
    };
}
