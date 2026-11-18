const std = @import("std");
const Flow = @import("../flow.zig");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_flow_advance") else void;
const seed = @import("traversal/seed.zig");
pub const Region = if (generated) @FieldType(std.meta.Child(rule.Input), "region") else seed.Region;
const Event = if (generated) @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload else seed.Event;

pub const Cursor = struct {
    first: usize,
    end: usize,
    pub fn body(unit: Flow.Unit) Cursor {
        return .{ .first = unit.first, .end = @as(usize, unit.first) + unit.count };
    }
    pub fn cases(count: usize) Cursor {
        return .{ .first = 0, .end = count };
    }
    fn advance(self: Cursor, region: Region, plan: *const Flow.Plan) Event {
        if (comptime !generated) return seed.advance(plan, region, self.first, self.end);

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), &.{
            .region = region,
            .kinds = plan.kinds,
            .items = plan.items,
            .first = self.first,
            .end = self.end,
        }) catch unreachable;
    }
};

pub fn run(state: anytype, plan: *const Flow.Plan) @TypeOf(state.closeCase()) {
    while (true) {
        const current = state.frame();
        const first = current.cursor.first;
        const batch = current.cursor.advance(std.meta.activeTag(current.payload), plan);
        const position: usize = @intCast(batch.position);

        current.cursor.first = @intCast(batch.next);

        if (first < position) try state.calls(current, first, plan.items[first..position]);

        switch (batch.action) {
            .Done => return,
            .Return => try state.result(current, position, batch.item),
            .OpenTask, .OpenParallelTask => try state.task(current, position, batch.item, batch.action == .OpenParallelTask),
            .OpenParallel => try state.parallel(current, position, batch.item),
            .OpenSelection => try state.selection(current, position, batch.item),
            .OpenCase => try state.openCase(current, position),
            .CloseTask, .CloseParallelTask => try state.closeTask(batch.action == .CloseParallelTask),
            .CloseParallel => try state.closeParallel(),
            .CloseSelection => try state.closeSelection(),
            .CloseCase => try state.closeCase(),
        }

        if (batch.pop) state.pop();
    }
}
