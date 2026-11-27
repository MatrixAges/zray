const std = @import("std");
const Memo = @import("../memo.zig");
const Function = @import("../function.zig");
const Growth = @import("../growth.zig");
const Level = @import("../level.zig").Level;
const disk = @import("disk.zig");
const Error = std.mem.Allocator.Error;

pub fn load(memo: *Memo, source: []const u8) Error!void {
    const owner = memo.arena.child_allocator;
    const layout = (try disk.inspect(owner, source)) orelse return;
    const loader: Loader = .{ .owner = owner, .payload = memo.arena.allocator(), .source = source };

    try loader.settled(&memo.settled, .{ .start = layout.settled_start, .count = layout.settled_count });
    try loader.demanded(&memo.demanded, .{ .start = layout.demanded_start, .count = layout.demanded_count });
    try loader.planned(&memo.planned, .{ .start = layout.planned_start, .count = layout.planned_count });
    try loader.flowed(&memo.flowed, .{ .start = layout.flowed_start, .count = layout.flowed_count });
}

const Span = struct { start: u64, count: u32 };

fn toLevel(byte: u8) Level {
    return @bitCast(@as(u3, @intCast(byte)));
}

fn decodeLevels(allocator: std.mem.Allocator, bytes: []const u8) Error![]const Level {
    const out = try allocator.alloc(Level, bytes.len);

    for (bytes, 0..) |b, i| out[i] = toLevel(b);

    return out;
}

fn decodeBools(allocator: std.mem.Allocator, bytes: []const u8) Error![]const bool {
    const out = try allocator.alloc(bool, bytes.len);

    for (bytes, 0..) |b, i| out[i] = b != 0;

    return out;
}

const Loader = struct {
    owner: std.mem.Allocator,
    payload: std.mem.Allocator,
    source: []const u8,
    fn decodeSection(self: Loader, comptime entry: type, table: anytype, bounds: Span) Error!@typeInfo(@typeInfo(@TypeOf(entry.executeIn)).@"fn".return_type.?).error_union.payload {
        try table.ensureUnusedCapacity(self.owner, bounds.count);

        const Input = std.meta.Child(entry.Input);
        const input: Input = .{ .source = self.source, .start = bounds.start, .count = bounds.count };

        const outcome = entry.executeIn(self.payload, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("validated memo section could not be decoded: {s}", .{@errorName(err)}),
        };

        if (!outcome.valid) @panic("validated memo section ended early");

        return outcome;
    }
    fn settled(self: Loader, table: anytype, bounds: Span) Error!void {
        if (bounds.count == 0) return;

        const outcome = try self.decodeSection(@import("generated_uniqueness_memo_load_settlement"), table, bounds);
        var ignored = false;

        for (outcome.records) |rec| {
            const passed = try self.payload.alloc(Function.Contribution, rec.passed.len);

            for (rec.passed, 0..) |item, i| {
                passed[i] = .{ .callee = item.callee, .levels = try decodeLevels(self.payload, item.levels) };
            }

            const value: Memo.Settled = .{
                .passed = passed,
                .output = try decodeLevels(self.payload, rec.output),
                .used = false,
            };

            _ = try table.put(self.owner, rec.digest[0..32].*, value, &ignored);
        }
    }
    fn demanded(self: Loader, table: anytype, bounds: Span) Error!void {
        if (bounds.count == 0) return;

        const outcome = try self.decodeSection(@import("generated_uniqueness_memo_load_demand"), table, bounds);
        var ignored = false;

        for (outcome.records) |rec| {
            const marks = try self.payload.alloc(Function.Mark, rec.marks.len);

            for (rec.marks, 0..) |item, i| {
                marks[i] = .{ .output = item.output, .function = item.function, .slot = item.slot, .want = toLevel(item.want) };
            }

            const normalized = try self.payload.alloc(Growth.Normalized, rec.normalized.len);

            for (rec.normalized, 0..) |item, i| {
                normalized[i] = .{ .id = @fromBackingInt(item.id), .want = toLevel(item.want) };
            }

            const renewed = try self.payload.alloc(Growth.Renewed, rec.renewed.len);

            for (rec.renewed, 0..) |item, i| {
                renewed[i] = .{ .key = item.key, .want = toLevel(item.want) };
            }

            const value: Memo.Demanded = .{
                .marks = marks,
                .normalized = normalized,
                .renewed = renewed,
                .grew = rec.grew,
                .used = false,
            };

            _ = try table.put(self.owner, rec.digest[0..32].*, value, &ignored);
        }
    }
    fn planned(self: Loader, table: anytype, bounds: Span) Error!void {
        if (bounds.count == 0) return;

        const outcome = try self.decodeSection(@import("generated_uniqueness_memo_load_plan"), table, bounds);
        var ignored = false;

        for (outcome.records) |rec| {
            const value: Memo.Planned = .{
                .flags = @ptrCast(rec.flags),
                .renewals = .{ .keys = rec.renewals.keys, .paths = rec.renewals.paths },
                .transfers = rec.transfers,
                .slot_first = rec.slot_first,
                .used = false,
            };

            _ = try table.put(self.owner, rec.digest[0..32].*, value, &ignored);
        }
    }
    fn flowed(self: Loader, table: anytype, bounds: Span) Error!void {
        if (bounds.count == 0) return;

        const outcome = try self.decodeSection(@import("generated_uniqueness_memo_load_flow"), table, bounds);
        var ignored = false;

        for (outcome.records) |rec| {
            const value: Memo.Flowed = .{
                .held = try decodeBools(self.payload, rec.held),
                .text_held = try decodeBools(self.payload, rec.text_held),
                .written = try decodeBools(self.payload, rec.written),
                .used = false,
            };

            _ = try table.put(self.owner, rec.digest[0..32].*, value, &ignored);
        }
    }
};
