const std = @import("std");
const zx = @import("zx");
const Round = @import("work/round.zig");
const Summaries = @import("summaries.zig");
const SummaryState = @import("summaries/lifecycle.zig");
const Topology = @import("topology.zig");
const Ahead = @import("ahead.zig");
const Memo = @import("memo.zig");
const dispatch = @import("work/dispatch.zig");
const opening = @import("generated_uniqueness_open_program");
const preparing = @import("generated_uniqueness_prepare_round");
const Queue = std.meta.Child(@FieldType(dispatch.Advance, "state"));
const Self = @This();

pub const Cursor = struct {
    head: u64 = 0,
    count: u64 = 0,
    budget: u64 = 0,
    grew: bool = false,
};

allocator: std.mem.Allocator,
slots: []u64,
queued: []u8,

cursor: Cursor = .{},
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

const QueueCursor = std.meta.Child(@FieldType(Queue, "cursor"));

fn queue(self: *Self, cursor: *const QueueCursor) Queue {
    return .{
        .queued = self.queued,
        .cursor = cursor,
        .capacity = self.slots.len,
    };
}

fn queueCursor(self: *const Self) QueueCursor {
    return .{
        .head = self.cursor.head,
        .count = self.cursor.count,
        .budget = self.cursor.budget,
        .grew = self.cursor.grew,
    };
}

pub fn prepare(self: *Self, summaries: *const Summaries, active: []const bool, known: []const bool, phase: Round.Phase, exhausted: bool) std.mem.Allocator.Error!void {
    const state = SummaryState.Borrowed.init(summaries);

    const fill_view: std.meta.Child(@FieldType(std.meta.Child(preparing.Input), "queue")) = .{
        .capacity = self.slots.len,
        .active = active,
    };

    const facts: std.meta.Child(@FieldType(std.meta.Child(preparing.Input), "facts")) = .{
        .layout = &state.layout,
        .active = active,
        .known = known,
    };

    const input: std.meta.Child(preparing.Input) = .{
        .queue = &fill_view,
        .facts = &facts,
        .phase = phase,
        .exhausted = exhausted,
    };

    var scratch_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(self.allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const prepared = try invoke(preparing, fallback.allocator(), &input);
    const count: usize = @intCast(prepared.cursor.count);

    @memcpy(self.queued, prepared.queued);
    @memcpy(self.slots[0..count], prepared.slots[0..count]);

    self.cursor = .{
        .head = prepared.cursor.head,
        .count = prepared.cursor.count,
        .budget = prepared.cursor.budget,
        .grew = prepared.cursor.grew,
    };

    if (prepared.guarantees) |guarantees| @memcpy(state.guarantees, guarantees);
}

pub fn advance(self: *Self, comptime kind: Memo.Kind, phase: Round.Phase, frame: *Round.Frame, previous: ?Round.Feedback, following: bool, ahead: *Ahead, memo: *Memo) std.mem.Allocator.Error!Round.Claim {
    const Input = dispatch.Advance;
    const Feedback = std.meta.Child(@typeInfo(@FieldType(Input, "previous")).optional.child);
    const Plan = std.meta.Child(@typeInfo(@FieldType(Feedback, "plan")).optional.child);
    const fields = if (previous) |value| value.plan else null;

    const plan: Plan = if (fields) |bytes| planned: {
        const target = frame.plans.?;

        break :planned .{
            .count = target.functions.len,
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

    const cursor = self.queueCursor();
    const queue_view = self.queue(&cursor);

    const input: Input = .{
        .state = &queue_view,
        .slots = self.slots,
        .phase = phase,
        .following = following,
        .outputs = @ptrCast(&frame.outputs),
        .active = frame.active,
        .callers = frame.callers,
        .previous = if (previous != null) &feedback else null,
    };

    return dispatch.run(ahead, memo, kind, &input, self, frame);
}

inline fn invoke(comptime entry: type, allocator: std.mem.Allocator, input: entry.Input) std.mem.Allocator.Error!@typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload {
    return zx.columns.invoke(entry.executeValue, allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership queue failed: {s}", .{@errorName(err)}),
    };
}
