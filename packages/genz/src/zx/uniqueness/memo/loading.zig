const std = @import("std");
const columns = @import("zx").columns;
const rows = @import("../row_output.zig");
const Memo = @import("../memo.zig");
const disk = @import("disk.zig");
const Error = std.mem.Allocator.Error;

pub fn load(memo: *Memo, source: []const u8) Error!void {
    const owner = memo.arena.child_allocator;
    const layout = (try disk.inspect(owner, source)) orelse return;
    const payload = memo.arena.allocator();

    try section(owner, payload, source, layout.settled_start, layout.settled_count, &memo.settled, settled);
    try section(owner, payload, source, layout.demanded_start, layout.demanded_count, &memo.demanded, demanded);
    try section(owner, payload, source, layout.planned_start, layout.planned_count, &memo.planned, planned);
    try section(owner, payload, source, layout.flowed_start, layout.flowed_count, &memo.flowed, flowed);
}

fn section(owner: std.mem.Allocator, payload: std.mem.Allocator, source: []const u8, start: u64, count: u32, map: anytype, comptime materialize: anytype) Error!void {
    try map.ensureUnusedCapacity(owner, count);

    var at = start;

    for (0..count) |_| {
        const row = try materialize(payload, source, at);

        map.putAssumeCapacity(row.digest[0..@sizeOf(Memo.Digest)].*, row.value);

        at = row.end;
    }
}

fn Row(comptime T: type) type {
    return struct { value: T, end: u64, digest: []const u8 };
}

fn settled(allocator: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Settled) {
    const entry = @import("generated_uniqueness_memo_load_settlement");
    const Input = std.meta.Child(entry.Input);
    var passed: rows.Contributions(Input, "passed") = undefined;

    passed.init();

    const input: Input = .{
        .source = source,
        .start = start,
        .passed = &.{ .storage = @ptrCast(&passed.buffer), .columns = &passed.view },
    };

    const row = try decode(entry, allocator, input) orelse unreachable;

    return .{
        .value = .{ .passed = passed.rows(), .output = @ptrCast(row.output), .used = false },
        .end = row.end,
        .digest = row.digest,
    };
}

fn demanded(allocator: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Demanded) {
    const entry = @import("generated_uniqueness_memo_load_demand");
    const Input = std.meta.Child(entry.Input);
    var marks: rows.Marks(Input, "marks") = undefined;
    var normalized: rows.Normalized(Input) = undefined;
    var renewed: rows.Renewed(Input) = undefined;

    marks.init();
    normalized.init();
    renewed.init();

    const input: Input = .{
        .source = source,
        .start = start,
        .marks = &.{ .storage = @ptrCast(&marks.buffer), .columns = &marks.view },
        .normalized = &.{ .storage = @ptrCast(&normalized.buffer), .columns = &normalized.view },
        .renewed = &.{ .storage = @ptrCast(&renewed.buffer), .columns = &renewed.view },
    };

    const row = try decode(entry, allocator, input) orelse unreachable;

    return .{
        .value = .{ .marks = marks.rows(), .normalized = normalized.rows(), .renewed = renewed.rows(), .grew = row.grew, .used = false },
        .end = row.end,
        .digest = row.digest,
    };
}

fn planned(allocator: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Planned) {
    const row = try decode(@import("generated_uniqueness_memo_load_plan"), allocator, .{ .source = source, .start = start }) orelse unreachable;

    return .{
        .value = .{
            .flags = @ptrCast(row.flags),
            .renewals = .{ .keys = row.renewals.keys, .paths = row.renewals.paths },
            .transfers = row.transfers,
            .slot_first = row.slot_first,
            .used = false,
        },
        .end = row.end,
        .digest = row.digest,
    };
}

fn flowed(allocator: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Flowed) {
    const row = try decode(@import("generated_uniqueness_memo_load_flow"), allocator, .{ .source = source, .start = start }) orelse unreachable;

    return .{
        .value = .{
            .held = @ptrCast(row.held),
            .text_held = @ptrCast(row.text_held),
            .written = @ptrCast(row.written),
            .used = false,
        },
        .end = row.end,
        .digest = row.digest,
    };
}

fn decode(comptime entry: type, memory: std.mem.Allocator, source: anytype) Error!@typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload {
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const input = columns.view(Input, source);

    return entry.executeValue(memory, if (indirect) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("validated memo row could not be decoded: {s}", .{@errorName(err)}),
    };
}
