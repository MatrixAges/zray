const std = @import("std");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_flow_traversal") else void;
const Input = if (generated) std.meta.Child(rule.Input) else void;
const Result = if (generated) @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload else void;

const Event = if (generated) (if (@typeInfo(Result) == .pointer) std.meta.Child(Result) else Result) else struct {
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
    items: []const u32,
};

pub const Region = if (generated) @FieldType(Input, "region") else enum {
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
        if (comptime !generated) return self.seed(region, plan);

        const input: Input = .{
            .region = region,
            .first = self.first,
            .end = self.end,
            .kinds = plan.kinds,
            .items = plan.items,
        };

        var buffer: [@sizeOf(Event)]u8 align(@alignOf(Event)) = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);
        const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
        const event = if (comptime @typeInfo(Result) == .pointer) result.* else result;

        self.first = @intCast(event.next);

        return event;
    }
    fn seed(self: *Cursor, region: Region, plan: *const Flow.Plan) Event {
        const first = self.first;

        if (first == self.end) {
            return .{ .action = switch (region) {
                .Root => .Done,
                .Task => .CloseTask,
                .ParallelTask => .CloseParallelTask,
                .Parallel => .CloseParallel,
                .Selection => .CloseSelection,
                .Case => .CloseCase,
            }, .next = first, .items = &.{} };
        }

        if (region == .Selection) {
            self.first += 1;

            return .{ .action = .OpenCase, .next = self.first, .items = &.{} };
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
        }, .next = end, .items = plan.items[first..end] };
    }
};
