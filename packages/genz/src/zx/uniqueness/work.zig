const std = @import("std");
const ir = @import("zx").ir;
const Round = @import("work/round.zig");
const Summaries = @import("summaries.zig");
const SummaryState = @import("summaries/lifecycle.zig");
const creating = @import("generated_uniqueness_work_create");
const preparing = @import("generated_uniqueness_prepare_round");
const taking = @import("generated_uniqueness_take_settlement");
const publishing = @import("generated_uniqueness_publish_settlement");
const popping = @import("generated_uniqueness_work_pop");
const notifying = @import("generated_uniqueness_work_notify");
const State = @typeInfo(@typeInfo(@TypeOf(creating.executeState)).@"fn".return_type.?).error_union.payload;
const Self = @This();

arena: std.heap.ArenaAllocator,
state: State,
pub fn init(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Self {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const state = creating.executeState(arena.allocator(), size) catch |err| return failure(err);

    return .{ .arena = arena, .state = state };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn advance(self: *Self, program: *const ir.Program, summaries: *const Summaries, known: []const bool, event: Round.Event) std.mem.Allocator.Error!Round.Step {
    const Parameter = @typeInfo(@TypeOf(preparing.executeState)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const Queue = std.meta.Child(@FieldType(Input, "queue"));

    const queue: Queue = .{
        .state = self.state,
        .native_modules = .{ .items = program.functions.native_modules, .storage = .plain },
        .type_only = program.type_only,
    };

    // The preceding round has drained its readers, so this entry may reset the backing cells.
    const state = SummaryState.Borrowed.init(summaries);
    const facts = state.input(.Reset, program.functions.native_modules, known);
    const input: Input = .{ .queue = &queue, .facts = &facts, .event = event };
    const output = preparing.executeState(self.arena.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);

    self.state = output.state;

    return .{ .phase = output.phase, .budget = output.budget };
}

pub fn publish(self: *Self, settlement: Round.Settlement) std.mem.Allocator.Error!void {
    comptime std.debug.assert(@sizeOf(std.meta.Elem(@TypeOf(settlement.levels))) == @sizeOf(u8));

    const Parameter = @typeInfo(@TypeOf(publishing.executeState)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const target = dirtyBytes(settlement.dirty);
    const program = settlement.program;

    const input: Input = .{
        .state = self.state,
        .dirty = @ptrCast(&target),
        .changed = .{ .items = settlement.changed, .storage = .plain },
        .native_modules = .{ .items = program.functions.native_modules, .storage = .plain },
        .callers = .{ .items = settlement.callers, .storage = .plain },
        .type_only = program.type_only,
        .body = settlement.body,
        .outputs = @ptrCast(&settlement.outputs),
        .levels = .{ .items = std.mem.sliceAsBytes(settlement.levels), .storage = .plain },
    };

    self.state = publishing.executeState(self.arena.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);
}

pub fn notify(self: *Self, dirty: []bool, program: ir.Program, changed: []const u64, callers: []const u64, demand_body: ?usize) std.mem.Allocator.Error!void {
    if (changed.len == 0) return;

    const Rule = @TypeOf(notifying.executeState);
    const Parameter = @typeInfo(Rule).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const target = dirtyBytes(dirty);

    const input: Input = .{
        .state = self.state,
        .dirty = @ptrCast(&target),
        .changed = .{ .items = changed, .storage = .plain },
        .native_modules = .{ .items = program.functions.native_modules, .storage = .plain },
        .type_only = program.type_only,
        .callers = .{ .items = callers, .storage = .plain },
        .demand_body = demand_body,
    };

    self.state = notifying.executeState(self.arena.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);
}

fn dirtyBytes(dirty: []bool) []u8 {
    comptime std.debug.assert(@sizeOf(bool) == @sizeOf(u8));

    return std.mem.sliceAsBytes(dirty);
}

pub fn pop(self: *Self) std.mem.Allocator.Error!?usize {
    const output = popping.executeState(self.arena.allocator(), self.state) catch |err| return failure(err);

    self.state = output.state;

    return if (output.index) |index| @intCast(index) else null;
}

pub fn takeSettlement(self: *Self, budget: *u64) std.mem.Allocator.Error!Round.Visit {
    const output = taking.executeState(self.arena.allocator(), .{ .state = self.state, .budget = budget.* }) catch |err| return failure(err);

    self.state = output.state;
    budget.* = output.budget;

    if (output.body) |body| return .{ .body = @intCast(body) };

    return if (output.exhausted) .exhausted else .done;
}

pub fn window(self: *const Self, size: usize) []const u64 {
    const start: usize = @intCast(self.state.head);
    const end: usize = @intCast(self.state.tail);

    return self.state.buffer.items[start..@min(end, start + size)];
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("work state failed: {s}", .{@errorName(err)});
}
