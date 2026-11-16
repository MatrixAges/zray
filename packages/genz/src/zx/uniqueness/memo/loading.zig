const std = @import("std");
const columns = @import("zx").columns;
const borrowColumn = @import("zxc_standard").memory.borrowWriteColumn;
const Memo = @import("../memo.zig");
const Function = @import("../function.zig");
const disk = @import("disk.zig");
const Error = std.mem.Allocator.Error;

pub fn load(memo: *Memo, source: []const u8) Error!void {
    const layout = (try disk.inspect(memo.arena.child_allocator, source)) orelse return;
    const allocator = memo.arena.allocator();
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const memory = empty.allocator();

    try section(allocator, memory, source, layout.settled_start, layout.settled_count, &memo.settled, settled);
    try section(allocator, memory, source, layout.demanded_start, layout.demanded_count, &memo.demanded, demanded);
    try section(allocator, memory, source, layout.planned_start, layout.planned_count, &memo.planned, planned);
    try section(allocator, memory, source, layout.flowed_start, layout.flowed_count, &memo.flowed, flowed);
}

fn section(allocator: std.mem.Allocator, memory: std.mem.Allocator, source: []const u8, start: u64, count: u32, map: anytype, comptime materialize: anytype) Error!void {
    try map.ensureUnusedCapacity(allocator, count);

    var at = start;

    for (0..count) |_| {
        const key = source[@intCast(at)..][0..@sizeOf(Memo.Digest)].*;
        const row = try materialize(allocator, memory, source, at + @sizeOf(Memo.Digest));

        map.putAssumeCapacity(key, row.value);

        at = row.end;
    }
}

fn Row(comptime T: type) type {
    return struct { value: T, end: u64 };
}

fn settled(allocator: std.mem.Allocator, memory: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Settled) {
    const shape = try decode(@import("generated_uniqueness_memo_disk_settled"), memory, .{ .source = source, .start = start, .trusted = true }) orelse unreachable;
    const passed = try allocator.alloc(Function.Contribution, shape.passed_count);
    const callees = borrowColumn(u32, "callee", passed);
    const levels = borrowColumn([]const u8, "levels", passed);
    const entry = @import("generated_uniqueness_memo_load_settlement");
    const Input = std.meta.Child(entry.Input);
    const layout = columns.view(std.meta.Child(@FieldType(Input, "shape")), shape);

    const input: Input = .{
        .source = source,
        .shape = &layout,
        .callees = @ptrCast(&callees),
        .levels = @ptrCast(&levels),
    };

    const output = try decode(entry, allocator, input);

    return .{
        .value = .{ .passed = passed, .output = @ptrCast(output), .used = false },
        .end = shape.end,
    };
}

fn demanded(allocator: std.mem.Allocator, memory: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Demanded) {
    const shape = try decode(@import("generated_uniqueness_memo_disk_demanded"), memory, .{ .source = source, .start = start, .trusted = true }) orelse unreachable;
    const marks = try allocator.alloc(Function.Mark, shape.marks_count);
    const normalized = try allocator.alloc(Memo.Normalized, shape.normalized_count);
    const renewed = try allocator.alloc(Memo.Renewed, shape.renewed_count);
    const output = borrowColumn(u8, "output", marks);
    const functions = borrowColumn(u32, "function", marks);
    const slots = borrowColumn(u32, "slot", marks);
    const mark_wants = borrowColumn(u8, "want", marks);
    const normalized_ids = borrowColumn(u32, "id", normalized);
    const normalized_wants = borrowColumn(u8, "want", normalized);
    const renewed_keys = borrowColumn(u64, "key", renewed);
    const renewed_wants = borrowColumn(u8, "want", renewed);
    const entry = @import("generated_uniqueness_memo_load_demand");
    const Input = std.meta.Child(entry.Input);
    const layout = columns.view(std.meta.Child(@FieldType(Input, "shape")), shape);

    const input: Input = .{
        .source = source,
        .shape = &layout,
        .output = @ptrCast(&output),
        .functions = @ptrCast(&functions),
        .slots = @ptrCast(&slots),
        .marks = @ptrCast(&mark_wants),
        .normalized_ids = @ptrCast(&normalized_ids),
        .normalized_wants = @ptrCast(&normalized_wants),
        .renewed_keys = @ptrCast(&renewed_keys),
        .renewed_wants = @ptrCast(&renewed_wants),
    };

    try decode(entry, memory, input);

    return .{
        .value = .{ .marks = marks, .normalized = normalized, .renewed = renewed, .grew = shape.grew, .used = false },
        .end = shape.end,
    };
}

fn planned(allocator: std.mem.Allocator, _: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Planned) {
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
    };
}

fn flowed(allocator: std.mem.Allocator, _: std.mem.Allocator, source: []const u8, start: u64) Error!Row(Memo.Flowed) {
    const row = try decode(@import("generated_uniqueness_memo_load_flow"), allocator, .{ .source = source, .start = start }) orelse unreachable;

    return .{
        .value = .{
            .held = @ptrCast(row.held),
            .text_held = @ptrCast(row.text_held),
            .written = @ptrCast(row.written),
            .used = false,
        },
        .end = row.end,
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
