const std = @import("std");
const rx = @import("rx");
const Flow = @import("../flow.zig");
const target = @import("../../call/target.zig");
const Prepare = @import("../prepare.zig");
const entry = @import("generated_rx_prepare_flow");
const Input = std.meta.Child(entry.Input);
const Index = std.meta.Child(@FieldType(Input, "index"));
const payload_lanes = 5;

pub fn bind(loader: *Prepare.Loader, indexed: rx.IndexedFlow) Prepare.Loader.Error!Flow.Plan {
    const allocator = loader.allocator;
    var state: State = .{ .loader = loader, .index = &indexed };
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
    const input: Input = .{ .index = &index, .rows = &rows, .count = indexed.events.len, .context = @ptrCast(&state) };

    entry.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFlow => return error.InvalidFlow,
        else => unreachable,
    };

    std.debug.assert(std.mem.eql(u32, &counters, &.{
        indexed.capacity.calls,
        indexed.capacity.results,
        indexed.capacity.tasks,
        indexed.capacity.groups,
        indexed.capacity.selections,
    }));

    return loader.plan.finish(indexed.rootUnit());
}

const Error = Prepare.Loader.Error;

pub const State = struct {
    loader: *Prepare.Loader,
    index: *const rx.IndexedFlow,
    fn node(self: *const State, slot: u64) *const rx.ast.Node {
        return &self.index.base[@intCast(slot)];
    }
    pub fn call(self: *State, slot: u64, item: u32, previous_end: u32) Error!void {
        const actual = try self.loader.call(self.node(slot).*, previous_end);

        std.debug.assert(actual == item);
    }

    pub fn result(self: *State, slot: u64, item: u32) void {
        self.loader.plan.results.items[item] = target.attribute(self.node(slot).*, "value");
    }

    pub fn taskResult(self: *State, slot: u64, item: u32) void {
        self.loader.plan.results.items[item] = target.attribute(self.node(slot).*, "out");
    }

    pub fn task(self: *State, slot: u64, item: u32, first: u32, count: u32, output: bool) void {
        const task_node = self.node(slot);

        self.loader.plan.tasks.items[item] = .{
            .node = task_node,
            .body = .{ .first = first, .count = count },
            .output = if (output) target.attribute(task_node.*, "out") else null,
        };
    }

    pub fn parallelTask(self: *State, slot: u64, item: u32, first: u32, count: u32, task_id: u64) void {
        self.loader.plan.tasks.items[item] = .{
            .id = @intCast(task_id),
            .node = self.node(slot),
            .body = .{ .first = first, .count = count },
        };
    }

    pub fn group(self: *State, item: u32, first: u32, count: u32) void {
        self.loader.plan.groups.items[item] = .{ .first = first, .count = count };
    }

    pub fn selection(self: *State, slot: u64, item: u32, conditional: bool, else_branch: bool) Error!void {
        const selection_node = self.node(slot);
        const subject = target.borrowAttribute(selection_node.*, "on").?;
        const cases = try @import("selection.zig").bind(self.loader.allocator, self.index, selection_node, subject, conditional, else_branch);
        self.loader.plan.selections.items[item] = .{ .subject = subject, .cases = cases };
    }

    pub fn taskReturns(self: *State, slot: u64) Error!void {
        const location = target.attribute(self.node(slot).*, "out").value_location;

        return self.loader.fail(location, "return_path", "Task.out and Return cannot both define the same task output");
    }
    pub fn unreachableStep(self: *State, slot: u64) Error!void {
        return self.loader.fail(self.node(slot).location, "return_path", "steps after a terminating Return, Switch or If are unreachable");
    }
    pub fn unsupportedStep(self: *State, slot: u64) Error!void {
        return self.loader.fail(self.node(slot).location, "unsupported", "RX execution supports Store declarations, Call, Return, Task, Switch, If and pure Parallel branches; events require host linking");
    }
};
