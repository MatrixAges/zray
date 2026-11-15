const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("../call/target.zig");
const Flow = @import("flow.zig");
const enabled = @import("rx_options").generated_graph;
const rule = if (enabled) @import("generated_rx_shortcut_route") else void;

pub fn lower(allocator: std.mem.Allocator, node: rx.ast.Node, index: usize, input_type: zx.ir.TypeId, output_type: zx.ir.TypeId) std.mem.Allocator.Error!struct { node: rx.ast.Node, input: ?*const rx.ast.Attribute, flow: Flow.Plan } {
    const route = describe(input_type, output_type);
    const invocation = try call(allocator, node, route.takes_input);
    var flow: Flow.Builder = .{};
    const first = try flow.reserve(allocator, route.steps);

    try flow.write(allocator, first, .{ .Call = index });
    if (route.result_row) |row| try flow.write(allocator, first + row, .{ .Result = try result(allocator, invocation) });

    return .{ .node = invocation, .input = if (route.takes_input) &invocation.attributes[1] else null, .flow = flow.finish(.{ .first = first, .count = route.steps }) };
}

const Route = if (enabled) @typeInfo(@typeInfo(@TypeOf(rule.executeValue)).@"fn".return_type.?).error_union.payload else struct {
    takes_input: bool,
    steps: u32,
    result_row: ?u32,
};

fn describe(input_type: zx.ir.TypeId, output_type: zx.ir.TypeId) Route {
    if (!enabled) {
        const void_type = @import("frontend").types.scalarId(.void);
        const returns_value = output_type != void_type;

        return .{ .takes_input = input_type != void_type, .steps = if (returns_value) 2 else 1, .result_row = if (returns_value) 1 else null };
    }

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(rule.Input) = .{
        .input_type = @backingInt(input_type),
        .output_type = @backingInt(output_type),
    };

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn call(allocator: std.mem.Allocator, node: rx.ast.Node, has_input: bool) std.mem.Allocator.Error!rx.ast.Node {
    const attributes = try allocator.alloc(rx.ast.Attribute, if (has_input) 2 else 1);

    attributes[0] = target.attribute(node, "fn");

    if (has_input) attributes[1] = .{
        .name = "in",
        .value = "$in",
        .kind = .expression,
        .location = attributes[0].location,
        .value_location = attributes[0].value_location,
    };

    return .{ .name = "Call", .location = node.location, .attributes = attributes };
}

fn result(allocator: std.mem.Allocator, node: rx.ast.Node) std.mem.Allocator.Error!rx.ast.Attribute {
    const attribute = node.attributes[0];

    const value = if (enabled)
        @import("generated_rx_shortcut_result").executeValue(allocator, attribute.value) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        }

    else block: {
        const binding = @import("../result_name.zig").resolve(node);

        break :block try std.fmt.allocPrint(allocator, "$ctx.{s}", .{binding.name});
    };

    return .{
        .name = "value",
        .value = value,
        .kind = .expression,
        .location = attribute.location,
        .value_location = attribute.value_location,
    };
}
