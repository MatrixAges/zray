const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("../call/target.zig");
const Flow = @import("flow.zig");
const enabled = @import("rx_options").generated_graph;
const rule = if (enabled) @import("generated_rx_shortcut_lower") else void;
pub const call_index = 0;

pub fn nextDeferred(modules: []const @import("prepare.zig").Module, first: usize) ?usize {
    if (first == modules.len) return null;

    if (comptime enabled) {
        const Module = std.meta.Elem(@TypeOf(modules));

        comptime if (@sizeOf(@FieldType(Module, "deferred_shortcut")) != @sizeOf(u8)) @compileError("Incompatible layout for borrowing deferred shortcut marks");

        const scan = @import("generated_rx_shortcut_deferred");
        const bytes = std.mem.sliceAsBytes(modules);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const result = scan.executeValue(empty.allocator(), &.{
            .marks = bytes[@offsetOf(Module, "deferred_shortcut")..],
            .stride = @sizeOf(Module),
            .start = first,
            .count = modules.len,
        }) catch unreachable;

        return if (result) |row| @intCast(row) else null;
    }

    for (modules[first..], first..) |*module, row| {
        if (module.deferred_shortcut) return row;
    }

    return null;
}

pub fn call(node: rx.ast.Node) rx.ast.Node {
    const attribute = target.borrowAttribute(node, "fn").?;
    const attributes: *const [1]rx.ast.Attribute = @ptrCast(attribute);

    return .{ .name = "Call", .location = node.location, .attributes = attributes };
}

pub fn lower(allocator: std.mem.Allocator, node: rx.ast.Node, index: usize, input_type: zx.ir.TypeId, output_type: zx.ir.TypeId) std.mem.Allocator.Error!struct { node: rx.ast.Node, input: ?*const rx.ast.Attribute, flow: Flow.Plan } {
    const attribute = &node.attributes[0];
    const route = try describe(allocator, node, input_type, output_type);
    var invocation = node;

    if (route.takes_input) {
        const attributes = try allocator.alloc(rx.ast.Attribute, 2);
        attributes[0] = attribute.*;
        attributes[1] = expression(attribute, "in", "$in");
        invocation.attributes = attributes;
    }

    const results: u32 = @intFromBool(route.result != null);

    var flow = try Flow.Builder.init(allocator, .{
        .steps = route.steps,
        .calls = 1,
        .results = results,
        .tasks = 0,
        .groups = 0,
        .selections = 0,
    });

    flow.rows.set(0, .{ .kind = .Call, .item = std.math.cast(u32, index) orelse return error.OutOfMemory });

    if (route.result) |value| {
        flow.rows.set(1, .{ .kind = .Result, .item = 0 });
        flow.results.items[0] = expression(attribute, "value", value);
    }

    return .{
        .node = invocation,
        .input = if (route.takes_input) &invocation.attributes[1] else null,
        .flow = flow.finish(.{ .count = route.steps }),
    };
}

const Route = if (enabled) @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload else struct {
    takes_input: bool,
    steps: u32,
    result: ?[]const u8,
};

fn describe(allocator: std.mem.Allocator, node: rx.ast.Node, input_type: zx.ir.TypeId, output_type: zx.ir.TypeId) std.mem.Allocator.Error!Route {
    if (comptime enabled) {
        return rule.executeValue(allocator, &.{
            .ports = &.{ .input_type = @backingInt(input_type), .output_type = @backingInt(output_type) },
            .function_path = node.attributes[0].value,
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
            else => unreachable,
        };
    }

    const void_type = @import("frontend").types.scalarId(.void);
    const returns_value = output_type != void_type;
    const value = if (returns_value) try std.fmt.allocPrint(allocator, "$ctx.{s}", .{@import("../result_name.zig").resolve(node).name}) else null;

    return .{ .takes_input = input_type != void_type, .steps = if (returns_value) 2 else 1, .result = value };
}

fn expression(attribute: *const rx.ast.Attribute, name: []const u8, value: []const u8) rx.ast.Attribute {
    return .{
        .name = name,
        .value = value,
        .kind = .expression,
        .location = attribute.location,
        .value_location = attribute.value_location,
    };
}
