const Flow = @import("../../flow.zig");
pub const Region = enum { Root, Task, Selection, Case };

const Action = enum {
    Done,
    Calls,
    Parallel,
    Return,
    ReturnBorrowed,
    OpenTask,
    OpenSelection,
    OpenCase,
    CloseTask,
    EvaluateTask,
    BindTask,
    CloseSelection,
    CloseCase,
};

const Input = struct {
    region: Region,
    position: usize,
    end: usize,
    scope_step: usize,
    case_first: u32,
    borrow_root: bool,
};

pub const Event = struct {
    action: Action,
    next: usize,
    first: ?u32 = null,
    count: ?u32 = null,
    unit: ?u32 = null,
    target: ?u32 = null,
    exhaustive: ?bool = null,
};

pub fn advance(flow: *const Flow, in: Input) Event {
    const steps = flow.steps.slice();
    const row = in.position;

    if (row == in.end) return switch (in.region) {
        .Root => .{ .action = .Done, .next = row },
        .Task => .{ .action = switch (steps.items(.output)[in.scope_step]) {
            .None => .CloseTask,
            .Evaluate => .EvaluateTask,
            .Constant => .BindTask,
        }, .next = row },
        .Selection => .{ .action = .CloseSelection, .next = row, .count = steps.items(.count)[in.scope_step], .exhaustive = steps.items(.exhaustive)[in.scope_step] },
        .Case => .{ .action = .CloseCase, .next = row },
    };

    const next = row + 1;

    if (in.region == .Selection) {
        const child = flow.cases.items(.body)[row];
        const unit = flow.units.get(child);
        const offset: u32 = @intCast(row - steps.items(.first)[in.scope_step]);

        return .{ .action = .OpenCase, .next = next, .first = unit.first, .count = unit.count, .unit = child, .target = in.case_first + offset };
    }

    const kinds = steps.items(.kind);

    return switch (kinds[row]) {
        .Call => calls: {
            var end = next;

            while (end < in.end and kinds[end] == .Call) : (end += 1) {}

            break :calls .{ .action = .Calls, .next = end };
        },
        .Parallel => .{ .action = .Parallel, .next = next, .first = steps.items(.first)[row], .count = steps.items(.count)[row] },
        .Return => .{ .action = if (in.region == .Root and in.borrow_root) .ReturnBorrowed else .Return, .next = next },
        .Task => task: {
            const unit = flow.units.get(steps.items(.first)[row]);

            break :task .{ .action = .OpenTask, .next = next, .first = unit.first, .count = unit.count };
        },
        .Selection => .{ .action = .OpenSelection, .next = next, .first = steps.items(.first)[row], .count = steps.items(.count)[row] },
    };
}
