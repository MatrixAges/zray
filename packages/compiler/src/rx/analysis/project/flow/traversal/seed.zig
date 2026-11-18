const Flow = @import("../../flow.zig");
pub const Region = enum { Root, Task, ParallelTask, Parallel, Selection, Case };

pub const Event = struct {
    action: enum { Done, Return, OpenTask, OpenParallelTask, OpenParallel, OpenSelection, OpenCase, CloseTask, CloseParallelTask, CloseParallel, CloseSelection, CloseCase },
    next: usize,
    position: usize,
    item: u32 = 0,
    pop: bool = false,
};

pub fn advance(plan: *const Flow.Plan, region: Region, first: usize, end: usize) Event {
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
