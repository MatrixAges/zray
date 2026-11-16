const std = @import("std");
const ir = @import("zx").ir;
const creating = @import("generated_uniqueness_work_create");
const filling = @import("generated_uniqueness_work_fill");
const popping = @import("generated_uniqueness_work_pop");
const broadcasting = @import("generated_uniqueness_work_enqueue");
const notifying = @import("generated_uniqueness_work_notify");
const State = @typeInfo(@typeInfo(@TypeOf(creating.executeState)).@"fn".return_type.?).error_union.payload;
const FillParameter = @typeInfo(@TypeOf(filling.executeState)).@"fn".param_types[1].?;
const indirect_fill = @typeInfo(FillParameter) == .pointer;
const Fill = if (indirect_fill) std.meta.Child(FillParameter) else FillParameter;
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

pub fn fill(self: *Self, program: ir.Program) std.mem.Allocator.Error!void {
    const input: Fill = .{
        .state = self.state,
        .native_modules = .{ .items = program.functions.native_modules, .storage = .plain },
        .type_only = program.type_only,
    };

    self.state = filling.executeState(self.arena.allocator(), if (indirect_fill) &input else input) catch |err| return failure(err);
}

pub fn enqueue(self: *Self, dirty: []bool, indices: []const u64) std.mem.Allocator.Error!void {
    if (indices.len == 0) return;

    const Rule = @TypeOf(broadcasting.executeState);
    const Parameter = @typeInfo(Rule).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const target = dirtyBytes(dirty);

    const input: Input = .{
        .state = self.state,
        .dirty = @ptrCast(&target),
        .indices = .{ .items = indices, .storage = .plain },
    };

    self.state = broadcasting.executeState(self.arena.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);
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

pub fn window(self: *const Self, size: usize) []const u64 {
    const start: usize = @intCast(self.state.head);
    const end: usize = @intCast(self.state.tail);

    return self.state.buffer.items[start..@min(end, start + size)];
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("work state failed: {s}", .{@errorName(err)});
}
