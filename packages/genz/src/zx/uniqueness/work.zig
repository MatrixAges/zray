const std = @import("std");
const zx = @import("zx");
const Round = @import("work/round.zig");
const Summaries = @import("summaries.zig");
const SummaryState = @import("summaries/lifecycle.zig");
const Topology = @import("topology.zig");
const opening = @import("generated_uniqueness_open_program");
const preparing = @import("generated_uniqueness_prepare_round");
const advancing = @import("generated_uniqueness_work_advance");
const Queue = std.meta.Child(@FieldType(std.meta.Child(advancing.Input), "state"));
const Self = @This();
const position_count = 4;

allocator: std.mem.Allocator,
slots: []u64,
queued: []u8,

positions: [position_count]u64 = undefined,
pub fn open(owner: std.mem.Allocator, scratch: std.mem.Allocator, called: []const []const u32, exported: []const zx.ir.FunctionId) std.mem.Allocator.Error!struct { work: Self, reverse: Topology.Plan } {
    var slots: zx.memory.RowBuffer = .empty(u64);
    var queued: zx.memory.RowBuffer = .empty(u8);

    errdefer owner.free(slots.rows(u64));
    errdefer owner.free(queued.rows(u8));

    const input: std.meta.Child(opening.Input) = .{
        .callees = called,
        .exported = @ptrCast(exported),
        .queue = &.{
            .owner = @ptrCast(&owner),
            .slots = @ptrCast(&slots),
            .queued = @ptrCast(&queued),
        },
    };

    const reverse = try invoke(opening, scratch, &input);

    return .{
        .work = .{ .allocator = owner, .slots = slots.rows(u64), .queued = queued.rows(u8) },
        .reverse = .{ .callers = reverse.callers, .known = reverse.known },
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.queued);
    self.allocator.free(self.slots);
}

fn queue(self: *const Self, positions: *const []const u64) Queue {
    return .{
        .slots = @ptrCast(&self.slots),
        .queued = @ptrCast(&self.queued),
        .positions = @ptrCast(positions),
        .capacity = self.slots.len,
    };
}

pub fn prepare(self: *Self, summaries: *const Summaries, active: []const bool, known: []const bool, phase: Round.Phase, exhausted: bool) std.mem.Allocator.Error!void {
    const state = SummaryState.Borrowed.init(summaries);
    const facts = state.input(.Reset, active, known);
    const positions: []const u64 = &self.positions;

    const input: std.meta.Child(preparing.Input) = .{
        .queue = &.{ .state = &self.queue(&positions), .active = active },
        .facts = &facts,
        .phase = phase,
        .exhausted = exhausted,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return invoke(preparing, empty.allocator(), &input);
}

pub fn advance(self: *Self, phase: Round.Phase, frame: *const Round.Frame, previous: ?Round.Feedback, following: bool) std.mem.Allocator.Error!Round.Claim {
    const flags = std.mem.sliceAsBytes(frame.dirty);
    const positions: []const u64 = &self.positions;
    const Input = std.meta.Child(advancing.Input);
    const Feedback = std.meta.Child(@typeInfo(@FieldType(Input, "previous")).optional.child);
    const Plan = std.meta.Child(@typeInfo(@FieldType(Feedback, "plan")).optional.child);
    const fields = if (previous) |value| value.plan else null;

    const plan: Plan = if (fields) |bytes| planned: {
        const target = if (frame.plans) |*value| value else unreachable;

        break :planned .{
            .plans = @ptrCast(&target.functions),
            .entry = @ptrCast(&target.entry),
            .count = target.functions.count,
            .body = previous.?.body,
            .fields = bytes,
        };
    } else undefined;

    const feedback: Feedback = if (previous) |value| .{
        .body = value.body,
        .changed = value.changed,
        .levels = std.mem.sliceAsBytes(value.levels),
        .grew = value.grew,
        .plan = if (fields != null) &plan else null,
    } else undefined;

    const input: Input = .{
        .state = &self.queue(&positions),
        .slots = self.slots,
        .phase = phase,
        .following = following,
        .outputs = @ptrCast(&frame.outputs),
        .active = frame.active,
        .dirty = @ptrCast(&flags),
        .callers = frame.callers,
        .previous = if (previous != null) &feedback else null,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const output = try invoke(advancing, empty.allocator(), &input);

    return .{
        .visit = if (output.body) |body| .{ .body = @intCast(body) } else if (output.exhausted) .exhausted else .done,
        .pending = .{ .first = output.first, .second = output.second },
        .grew = output.grew,
        .prefetch = output.prefetch,
    };
}

inline fn invoke(comptime entry: type, allocator: std.mem.Allocator, input: entry.Input) std.mem.Allocator.Error!@typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload {
    return zx.columns.invoke(entry.executeValue, allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership queue failed: {s}", .{@errorName(err)}),
    };
}
