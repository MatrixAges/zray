const std = @import("std");
const Function = @import("../function.zig");
const Level = @import("../level.zig").Level;
const Summaries = @import("../summaries.zig");
const rows = @import("../row_output.zig");

pub fn contributions(allocator: std.mem.Allocator, summaries: *Summaries, values: []const Function.Contribution) std.mem.Allocator.Error![]const u64 {
    if (values.len == 0) return &.{};

    const entry = @import("generated_uniqueness_replay_contributions");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const source = rows.ContributionRows.init(values);

    const input: Input = .{
        .inputs = @ptrCast(&summaries.input),
        .contributions = &source.view(rows.Target(Input, "contributions")),
    };

    var buffer: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const result = entry.executeValue(scratch.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return replayError(err);
    const changed = try allocator.dupe(u64, result.changed);

    commit(summaries.input, &.{}, result.updates);

    return changed;
}

/// Foreground visits publish while workers may still read these same bytes.
pub fn commit(inputs: [][]Level, outputs: [][]Level, updates: anytype) void {
    for (updates) |update| {
        const target = if (update.output) outputs else inputs;
        const byte: *u8 = @ptrCast(&target[update.row][update.slot]);

        @atomicStore(u8, byte, update.value, .monotonic);
    }
}

fn replayError(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("summary replay failed: {s}", .{@errorName(err)});
}
