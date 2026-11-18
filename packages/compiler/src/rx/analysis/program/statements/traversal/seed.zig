const Flow = @import("../../flow.zig");
pub const Region = enum { Root, Task, Selection, Case };

const Action = enum {
    Done,
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

pub const Input = struct {
    shape: void,
    region: Region,
    position: usize,
    end: usize,
    scope_step: usize,
    case_first: u32,
    borrow_root: bool,
};

const Event = struct {
    action: Action,
    next: usize,
    position: usize,
    pop: bool = false,
    first: ?u32 = null,
    count: ?u32 = null,
    unit: ?u32 = null,
    target: ?u32 = null,
    exhaustive: ?bool = null,
};

pub fn advance(flow: *const Flow, in: Input) Event {
    const steps = flow.steps.slice();
    const kinds = steps.items(.kind);
    var row = in.position;

    if (in.region != .Selection) {
        while (row < in.end and kinds[row] == .Call) row += 1;
    }

    if (row == in.end) return switch (in.region) {
        .Root => .{ .action = .Done, .next = row, .position = row },
        .Task => .{ .action = switch (steps.items(.output)[in.scope_step]) {
            .None => .CloseTask,
            .Evaluate => .EvaluateTask,
            .Constant => .BindTask,
        }, .next = row, .position = row, .pop = true },
        .Selection => .{ .action = .CloseSelection, .next = row, .position = row, .pop = true, .count = steps.items(.count)[in.scope_step], .exhaustive = steps.items(.exhaustive)[in.scope_step] },
        .Case => .{ .action = .CloseCase, .next = row, .position = row, .pop = true },
    };

    const next = row + 1;

    if (in.region == .Selection) {
        const child = flow.cases.items(.body)[row];
        const unit = flow.units.get(child);
        const offset: u32 = @intCast(row - steps.items(.first)[in.scope_step]);

        return .{ .action = .OpenCase, .next = next, .position = row, .first = unit.first, .count = unit.count, .unit = child, .target = in.case_first + offset };
    }

    return switch (kinds[row]) {
        .Call => unreachable,
        .Parallel => .{ .action = .Parallel, .next = next, .position = row, .first = steps.items(.first)[row], .count = steps.items(.count)[row] },
        .Return => .{ .action = if (in.region == .Root and in.borrow_root) .ReturnBorrowed else .Return, .next = next, .position = row },
        .Task => task: {
            const unit = flow.units.get(steps.items(.first)[row]);

            break :task .{ .action = .OpenTask, .next = next, .position = row, .first = unit.first, .count = unit.count };
        },
        .Selection => .{ .action = .OpenSelection, .next = next, .position = row, .first = steps.items(.first)[row], .count = steps.items(.count)[row] },
    };
}
