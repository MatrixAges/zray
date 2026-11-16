const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const target = @import("../../call/target.zig");
const next = @import("generated_rx_prepared_flow_event");
const Input = std.meta.Child(next.Input);
const Index = std.meta.Child(@FieldType(Input, "index"));
const payload_lanes = 5;

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

    const headers = plan.rows.slice();
    const kinds = std.mem.sliceAsBytes(headers.items(.kind));
    const items = headers.items(.item);
    var counters: [payload_lanes]u32 = @splat(0);
    const cursors: []u32 = &counters;
    const Rows = std.meta.Child(@FieldType(Input, "rows"));

    const rows: Rows = .{
        .kinds = @ptrCast(&kinds),
        .items = @ptrCast(&items),
        .cursors = @ptrCast(&cursors),
        .codes = &.{
            .call = @backingInt(Flow.Kind.Call),
            .result = @backingInt(Flow.Kind.Result),
            .task = @backingInt(Flow.Kind.Task),
            .parallel_task = @backingInt(Flow.Kind.ParallelTask),
            .parallel = @backingInt(Flow.Kind.Parallel),
            .selection = @backingInt(Flow.Kind.Selection),
        },
    };

    comptime {
        if (@sizeOf(Flow.Kind) != @sizeOf(u8)) @compileError("indexed flow kinds must fit in one byte");
    }

    var remaining: usize = indexed.events.len;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (remaining != 0) {
        const input: Input = .{ .index = &index, .remaining = remaining, .rows = &rows };
        const event = zx.columns.invoke(next.executeValue, empty.allocator(), &input) catch unreachable;

        if (event.route == .Done) break;

        remaining = @intCast(event.remaining);

        const node = &indexed.base[@intCast(event.slot)];
        const body: Flow.Unit = .{ .first = event.first, .count = event.count };

        switch (event.route) {
            .Done => unreachable,
            .TaskReturns => return loader.fail(target.attribute(node.*, "out").value_location, "return_path", "Task.out and Return cannot both define the same task output"),
            .Unreachable => return loader.fail(node.location, "return_path", "steps after a terminating Return, Switch or If are unreachable"),
            .Unsupported => return loader.fail(node.location, "unsupported", "RX execution supports Store declarations, Call, Return, Task, Switch, If and pure Parallel branches; events require host linking"),
            .Call => {
                const call = try loader.call(node.*);

                std.debug.assert(call == event.item);
            },
            .Result => plan.results.items[event.item] = target.attribute(node.*, "value"),
            .Task => plan.tasks.items[event.item] = .{
                .node = node,
                .body = body,
                .output = if (event.task_output) target.attribute(node.*, "out") else null,
            },
            .ParallelTask => {
                if (event.implicit_item) |item| plan.results.items[item] = target.attribute(node.*, "out");

                plan.tasks.items[event.item] = .{ .id = @intCast(event.task_id.?), .node = node, .body = body };
            },
            .Parallel => plan.groups.items[event.item] = body,
            .Switch, .If => {
                const subject = target.borrowAttribute(node.*, "on").?;
                const cases = try @import("selection.zig").bind(allocator, &indexed, node, subject, event.route == .If, event.else_branch);
                plan.selections.items[event.item] = .{ .subject = subject, .cases = cases };
            },
        }
    }

    std.debug.assert(std.mem.eql(u32, &counters, &.{
        indexed.capacity.calls,
        indexed.capacity.results,
        indexed.capacity.tasks,
        indexed.capacity.groups,
        indexed.capacity.selections,
    }));

    return plan.finish(indexed.rootUnit());
}
