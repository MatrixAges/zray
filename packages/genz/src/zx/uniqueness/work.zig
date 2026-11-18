const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Round = @import("work/round.zig");
const Summaries = @import("summaries.zig");
const SummaryState = @import("summaries/lifecycle.zig");
const preparing = @import("generated_uniqueness_prepare_round");
const advancing = @import("generated_uniqueness_work_advance");
const Queue = std.meta.Child(@FieldType(std.meta.Child(advancing.Input), "state"));
const Self = @This();

allocator: std.mem.Allocator,
slots: []u64,
queued: []u8,
positions: []u64,
pub fn init(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Self {
    const slots = try allocator.alloc(u64, size);

    errdefer allocator.free(slots);

    const queued = try allocator.alloc(u8, size);

    errdefer allocator.free(queued);

    return .{ .allocator = allocator, .slots = slots, .queued = queued, .positions = try allocator.alloc(u64, 2) };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.positions);
    self.allocator.free(self.queued);
    self.allocator.free(self.slots);
}

fn queue(self: *const Self) Queue {
    return .{
        .slots = @ptrCast(&self.slots),
        .queued = @ptrCast(&self.queued),
        .positions = @ptrCast(&self.positions),
        .capacity = self.slots.len,
    };
}

pub fn prepare(self: *Self, program: *const ir.Program, summaries: *const Summaries, known: []const bool, phase: Round.Phase, exhausted: bool) std.mem.Allocator.Error!u64 {
    const state = SummaryState.Borrowed.init(summaries);
    const facts = state.input(.Reset, program.functions.native_modules, known);

    const input: std.meta.Child(preparing.Input) = .{
        .queue = &.{ .state = &self.queue(), .native_modules = program.functions.native_modules, .type_only = program.type_only },
        .facts = &facts,
        .phase = phase,
        .exhausted = exhausted,
    };

    return invoke(preparing, &input);
}

pub fn advance(self: *Self, phase: Round.Phase, frame: *const Round.Frame, previous: ?Round.Feedback, progress: *Round.Progress) std.mem.Allocator.Error!Round.Claim {
    const flags = std.mem.sliceAsBytes(frame.dirty);
    const feedback = previous orelse Round.Feedback{ .body = 0, .changed = &.{} };

    const input: std.meta.Child(advancing.Input) = .{
        .state = &self.queue(),
        .phase = phase,
        .budget = progress.budget,
        .grew = progress.grew,
        .outputs = @ptrCast(&frame.outputs),
        .native_modules = frame.program.functions.native_modules,
        .type_only = frame.program.type_only,
        .dirty = @ptrCast(&flags),
        .callers = frame.callers,
        .previous = &.{
            .present = previous != null,
            .body = feedback.body,
            .changed = feedback.changed,
            .levels = std.mem.sliceAsBytes(feedback.levels),
            .grew = feedback.grew,
        },
    };

    const output = try invoke(advancing, &input);
    progress.* = .{ .budget = output.budget, .grew = output.grew };

    const first: usize = @intCast(output.first);

    return .{
        .visit = if (output.body) |body| .{ .body = @intCast(body) } else if (output.exhausted) .exhausted else .done,
        .pending = .{ .first = self.slots[first..][0..@intCast(output.prefix)], .second = self.slots[0..@intCast(output.suffix)] },
    };
}

inline fn invoke(comptime entry: type, input: entry.Input) std.mem.Allocator.Error!@typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership queue failed: {s}", .{@errorName(err)}),
    };
}
