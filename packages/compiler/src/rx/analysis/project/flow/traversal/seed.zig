const std = @import("std");
const Flow = @import("../../flow.zig");
pub const Region = enum { Root, Task, ParallelTask, Parallel, Selection, Case };

const Event = struct {
    action: enum { Done, Return, OpenTask, OpenParallelTask, OpenParallel, OpenSelection, OpenCase, CloseTask, CloseParallelTask, CloseParallel, CloseSelection, CloseCase },
    next: usize,
    position: usize,
    item: u32 = 0,
    pop: bool = false,
};

pub fn run(state: anytype, plan: *const Flow.Plan) @TypeOf(state.closeCase(true)) {
    while (true) {
        const current = state.frame();
        const first = current.cursor.first;
        const batch = advance(plan, std.meta.activeTag(current.payload), first, current.cursor.end);

        current.cursor.first = batch.next;

        if (first < batch.position) try state.calls(current, first, plan.items[first..batch.position]);

        switch (batch.action) {
            .Done => return,
            .Return => try state.result(current, batch.position, batch.item),
            .OpenTask, .OpenParallelTask => try state.task(current, batch.position, batch.item, batch.action == .OpenParallelTask),
            .OpenParallel => try state.parallel(current, batch.position, batch.item),
            .OpenSelection => try state.selection(current, batch.position, batch.item),
            .OpenCase => try state.openCase(current, batch.position),
            .CloseTask, .CloseParallelTask => try state.closeTask(batch.action == .CloseParallelTask),
            .CloseParallel => try state.closeParallel(),
            .CloseSelection => try state.closeSelection(),
            .CloseCase => try state.closeCase(true),
        }

        if (batch.pop) state.pop();
    }
}

fn advance(plan: *const Flow.Plan, region: Region, first: usize, end: usize) Event {
    var row = first;

    if (region != .Selection) {
        while (row < end and plan.kinds[row] == .Call) row += 1;
    }

    if (row == end) return .{
        .action = switch (region) {
            .Root => .Done,
            .Task => .CloseTask,
            .ParallelTask => .CloseParallelTask,
            .Parallel => .CloseParallel,
            .Selection => .CloseSelection,
            .Case => .CloseCase,
        },
        .position = row,
        .next = row,
        .pop = region != .Root,
    };

    if (region == .Selection) return .{ .action = .OpenCase, .position = row, .next = row + 1 };

    return .{
        .action = switch (plan.kinds[row]) {
            .Call => unreachable,
            .Result => .Return,
            .Task => .OpenTask,
            .ParallelTask => .OpenParallelTask,
            .Parallel => .OpenParallel,
            .Selection => .OpenSelection,
        },
        .position = row,
        .next = row + 1,
        .item = plan.items[row],
    };
}
