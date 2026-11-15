const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const target = @import("../../call/target.zig");
const next = @import("generated_rx_prepared_flow_event");
const Input = std.meta.Child(next.Input);
const Index = std.meta.Child(@FieldType(Input, "index"));

pub fn bind(loader: anytype, indexed: rx.IndexedFlow) @TypeOf(loader.*).Error!Flow.Plan {
    const allocator = loader.allocator;
    var plan = try Flow.Builder.init(allocator, indexed.capacity);

    try loader.calls.setCapacity(allocator, indexed.capacity.calls);

    const index: Index = .{
        .facts = @ptrCast(indexed.facts),
        .events = @ptrCast(indexed.events),
        .unit_firsts = indexed.unit_firsts,
        .unit_counts = indexed.unit_counts,
        .step_rows = indexed.step_rows,
        .parallel_tasks = indexed.parallel_tasks,
    };

    var remaining: usize = indexed.events.len;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (remaining != 0) {
        const input: Input = .{ .index = &index, .remaining = remaining };
        const event = zx.columns.invoke(next.executeValue, empty.allocator(), &input) catch unreachable;

        if (event.route == .Done) break;

        remaining = @intCast(event.remaining);

        const node = &indexed.base[@intCast(event.slot)];
        const body: Flow.Unit = .{ .first = event.first, .count = event.count };

        const operation: Flow.Operation = switch (event.route) {
            .Done => unreachable,
            .TaskReturns => return loader.fail(target.attribute(node.*, "out").value_location, "return_path", "Task.out and Return cannot both define the same task output"),
            .Unreachable => return loader.fail(node.location, "return_path", "steps after a terminating Return, Switch or If are unreachable"),
            .Unsupported => return loader.fail(node.location, "unsupported", "RX execution supports Store declarations, Call, Return, Task, Switch, If and pure Parallel branches; events require host linking"),
            .Call => .{ .Call = try loader.call(node.*) },
            .Result => .{ .Result = target.attribute(node.*, "value") },
            .Task => .{ .Task = .{ .node = node, .body = body, .output = target.optionalAttribute(node.*, "out") } },
            .ParallelTask => task: {
                const out = target.optionalAttribute(node.*, "out");

                if (out) |attribute| try plan.write(allocator, body.first + body.count - 1, .{ .Result = attribute });

                break :task .{ .ParallelTask = .{ .id = @intCast(event.task_id.?), .node = node, .body = body } };
            },
            .Parallel => .{ .Parallel = body },
            .Switch, .If => selection: {
                const subject = target.attribute(node.*, "on");

                const cases = if (event.route == .Switch)
                    try switchCases(allocator, indexed, node.children)
                else
                    try ifCases(allocator, indexed, node, subject);

                break :selection .{ .Selection = .{ .subject = subject, .cases = cases } };
            },
        };

        try plan.write(allocator, event.row, operation);
    }

    return plan.finish(indexed.rootUnit());
}

fn switchCases(allocator: std.mem.Allocator, indexed: rx.IndexedFlow, nodes: []const rx.ast.Node) std.mem.Allocator.Error![]Flow.Case {
    const cases = try allocator.alloc(Flow.Case, nodes.len);

    for (nodes, cases) |*node, *case| {
        case.* = .{
            .value = if (indexed.get(node).alternate) null else target.attribute(node.*, "value"),
            .body = indexed.unit(node),
        };
    }

    return cases;
}

fn ifCases(allocator: std.mem.Allocator, indexed: rx.IndexedFlow, node: *const rx.ast.Node, subject: rx.ast.Attribute) std.mem.Allocator.Error![]Flow.Case {
    const last = &node.children[node.children.len - 1];
    const has_else = indexed.get(last).alternate;
    const cases = try allocator.alloc(Flow.Case, if (has_else) 2 else 1);

    cases[0] = .{
        .value = .{ .name = "value", .value = "true", .kind = .expression, .location = subject.location, .value_location = subject.value_location },
        .body = indexed.unit(node),
    };

    if (has_else) cases[1] = .{ .value = null, .body = indexed.unit(last) };

    return cases;
}
