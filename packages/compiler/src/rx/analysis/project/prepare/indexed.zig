const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const target = @import("../../call/target.zig");
const Prepare = @import("../prepare.zig");
const entry = @import("generated_rx_prepare_flow");
const Input = std.meta.Child(entry.Input);
const Index = std.meta.Child(@FieldType(Input, "index"));
const payload_lanes = 5;

pub fn bind(loader: *Prepare.Loader, indexed: rx.IndexedFlow) Prepare.Loader.Error!Flow.Plan {
    const allocator = loader.allocator;
    loader.plan = try Flow.Builder.init(allocator, indexed.capacity);

    try loader.calls.setCapacity(allocator, indexed.capacity.calls);

    const index: Index = .{
        .facts = @ptrCast(indexed.facts),
        .events = @ptrCast(indexed.events),
        .unit_firsts = indexed.unit_firsts,
        .unit_counts = indexed.unit_counts,
        .step_rows = indexed.step_rows,
        .parallel_tasks = indexed.parallel_tasks,
    };

    const headers = loader.plan.rows.slice();
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

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var remaining: u64 = indexed.events.len;

    while (remaining != 0) {
        const input: Input = .{ .index = &index, .rows = &rows, .remaining = remaining };
        const event = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        remaining = event.remaining;

        if (event.route == .Done) break;

        const node = &indexed.base[@intCast(event.slot)];
        const item = event.item;
        const unit: Flow.Unit = .{ .first = event.first, .count = event.count };

        switch (event.route) {
            .Call => {
                const index_written = try loader.call(node.*, event.previous_end);

                std.debug.assert(index_written == item);
            },
            .Result => loader.plan.results.items[item] = target.attribute(node.*, "value"),
            .Task => loader.plan.tasks.items[item] = .{
                .node = node,
                .body = unit,
                .output = if (event.task_output) target.attribute(node.*, "out") else null,
            },
            .ParallelTask => {
                if (event.implicit_item) |result| loader.plan.results.items[result] = target.attribute(node.*, "out");

                loader.plan.tasks.items[item] = .{ .node = node, .body = unit, .id = @intCast(event.task_id.?) };
            },
            .Parallel => loader.plan.groups.items[item] = unit,
            .Switch, .If => {
                const subject = target.borrowAttribute(node.*, "on").?;
                const cases = try @import("selection.zig").bind(allocator, &indexed, node, subject, event.route == .If, event.else_branch);
                loader.plan.selections.items[item] = .{ .subject = subject, .cases = cases };
            },
            .TaskReturns, .Unreachable, .Unsupported => {
                const report = @import("generated_rx_prepare_diagnostic");
                const issue = report.executeValue(empty.allocator(), event.route) catch unreachable;
                const location = if (issue.at_output) target.attribute(node.*, "out").value_location else node.location;

                return loader.fail(location, issue.code, issue.message);
            },
            .Done => unreachable,
        }
    }

    std.debug.assert(std.mem.eql(u32, &counters, &.{
        indexed.capacity.calls,
        indexed.capacity.results,
        indexed.capacity.tasks,
        indexed.capacity.groups,
        indexed.capacity.selections,
    }));

    return loader.plan.finish(indexed.rootUnit());
}
