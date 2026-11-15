const std = @import("std");
const rx = @import("rx");
const Flow = @import("../flow.zig");
const target = @import("../../call/target.zig");

pub fn bind(loader: anytype, indexed: rx.IndexedFlow) @TypeOf(loader.*).Error!Flow.Plan {
    const allocator = loader.allocator;
    var plan = try Flow.Builder.init(allocator, indexed.capacity);

    try loader.calls.ensureTotalCapacityPrecise(allocator, indexed.capacity.calls);

    // The XML walk records the closing Task event first.
    var events = std.mem.reverseIterator(indexed.events);

    while (events.next()) |event| {
        const node = indexed.nodeAt(event);
        const fact = indexed.get(node);

        if (event.phase == .check_task) {
            if (fact.returns) return loader.fail(target.attribute(node.*, "out").value_location, "return_path", "Task.out and Return cannot both define the same task output");

            continue;
        }

        if (fact.unreachable_step) return loader.fail(node.location, "return_path", "steps after a terminating Return, Switch or If are unreachable");

        const operation: Flow.Operation = switch (fact.action) {
            .call => .{ .Call = try loader.call(node.*) },
            .result => .{ .Result = target.attribute(node.*, "value") },
            .task => task: {
                const body = indexed.unit(node);
                const out = target.optionalAttribute(node.*, "out");

                if (indexed.taskId(event)) |id| {
                    if (out) |attribute| try plan.write(allocator, body.first + body.count - 1, .{ .Result = attribute });

                    break :task .{ .ParallelTask = .{
                        .id = id,
                        .node = node,
                        .body = body,
                    } };
                }

                break :task .{ .Task = .{ .node = node, .body = body, .output = out } };
            },
            .parallel => .{ .Parallel = indexed.unit(node) },
            .switch_flow, .if_flow => selection: {
                const subject = target.attribute(node.*, "on");

                const cases = if (fact.action == .switch_flow)
                    try switchCases(allocator, indexed, node.children)
                else
                    try ifCases(allocator, indexed, node, subject);

                break :selection .{ .Selection = .{ .subject = subject, .cases = cases } };
            },
            else => return loader.fail(node.location, "unsupported", "RX execution supports Store declarations, Call, Return, Task, Switch, If and pure Parallel branches; events require host linking"),
        };

        try plan.write(allocator, indexed.step(node), operation);
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
