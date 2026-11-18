const Flow = @import("../flow.zig");

const Event = struct {
    action: enum {
        Done,
        Calls,
        Return,
        OpenTask,
        OpenParallelTask,
        OpenParallel,
        OpenSelection,
        OpenCase,
        CloseTask,
        CloseParallelTask,
        CloseParallel,
        CloseSelection,
        CloseCase,
    },
    next: u64,
};

pub const Region = enum(u8) {
    Root,
    Task,
    ParallelTask,
    Parallel,
    Selection,
    Case,
};

pub const Cursor = struct {
    first: usize,
    end: usize,
    pub fn body(unit: Flow.Unit) Cursor {
        return .{ .first = unit.first, .end = @as(usize, unit.first) + unit.count };
    }
    pub fn cases(count: usize) Cursor {
        return .{ .first = 0, .end = count };
    }
    pub fn advance(self: *Cursor, region: Region, plan: *const Flow.Plan) Event {
        const first = self.first;

        if (first == self.end) {
            return .{ .action = switch (region) {
                .Root => .Done,
                .Task => .CloseTask,
                .ParallelTask => .CloseParallelTask,
                .Parallel => .CloseParallel,
                .Selection => .CloseSelection,
                .Case => .CloseCase,
            }, .next = first };
        }

        if (region == .Selection) {
            self.first += 1;

            return .{ .action = .OpenCase, .next = self.first };
        }

        const kind = plan.kinds[first];
        var end = first + 1;

        if (kind == .Call) {
            while (end < self.end and plan.kinds[end] == .Call) : (end += 1) {}
        }

        self.first = end;

        return .{ .action = switch (kind) {
            .Call => .Calls,
            .Result => .Return,
            .Task => .OpenTask,
            .ParallelTask => .OpenParallelTask,
            .Parallel => .OpenParallel,
            .Selection => .OpenSelection,
        }, .next = end };
    }
};
