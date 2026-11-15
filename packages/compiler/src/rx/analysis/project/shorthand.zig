const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("../call/target.zig");
const Flow = @import("flow.zig");

pub fn lower(allocator: std.mem.Allocator, node: rx.ast.Node, index: usize, input_type: zx.ir.TypeId, output_type: zx.ir.TypeId) std.mem.Allocator.Error!struct { node: rx.ast.Node, input: ?*const rx.ast.Attribute, flow: Flow.Plan } {
    const route = describe(input_type, output_type);
    const invocation = try call(allocator, node, route.takes_input);
    const count: u32 = if (route.returns_value) 2 else 1;
    var flow: Flow.Builder = .{};
    const first = try flow.reserve(allocator, count);

    try flow.write(allocator, first, .{ .Call = index });
    if (route.returns_value) try flow.write(allocator, first + 1, .{ .Result = try result(allocator, invocation) });

    return .{ .node = invocation, .input = if (route.takes_input) &invocation.attributes[1] else null, .flow = flow.finish(.{ .first = first, .count = count }) };
}

const Route = struct { takes_input: bool, returns_value: bool };

fn describe(input_type: zx.ir.TypeId, output_type: zx.ir.TypeId) Route {
    if (!@import("rx_options").generated_graph) {
        const void_type = @import("frontend").types.scalarId(.void);

        return .{ .takes_input = input_type != void_type, .returns_value = output_type != void_type };
    }

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const rule = @import("generated_rx_shortcut_route");

    const input: std.meta.Child(rule.Input) = .{
        .input_type = @backingInt(input_type),
        .output_type = @backingInt(output_type),
    };

    const generated = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .takes_input = generated.takes_input, .returns_value = generated.returns_value };
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
    const binding = @import("../result_name.zig").resolve(node);

    return .{
        .name = "value",
        .value = try std.fmt.allocPrint(allocator, "$ctx.{s}", .{binding.name}),
        .kind = .expression,
        .location = binding.attribute.location,
        .value_location = binding.attribute.value_location,
    };
}
