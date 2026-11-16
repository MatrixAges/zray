const std = @import("std");
const Level = @import("../level.zig").Level;
const Function = @import("../function.zig");
const Summaries = @import("../summaries.zig");
const storage = @import("zx").columns.storage;
const merging = @import("generated_uniqueness_function_updates");

pub fn merge(rows: [][]Level, row: u32, first: u32, levels: []const Level, joining: bool) usize {
    comptime {
        std.debug.assert(@sizeOf(Level) == @sizeOf(u8));
        std.debug.assert(@alignOf(Level) == @alignOf(u8));
    }

    const Parameter = @typeInfo(@TypeOf(merging.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;

    const input: Input = .{
        .rows = @ptrCast(&rows),
        .row = row,
        .first = first,
        .levels = std.mem.sliceAsBytes(levels),
        .joining = joining,
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return @intCast(merging.executeValue(memory.allocator(), if (indirect) &input else input) catch |err| {
        std.debug.panic("summary merge failed: {s}", .{@errorName(err)});
    });
}

pub fn contributions(allocator: std.mem.Allocator, summaries: *Summaries, values: []const Function.Contribution) std.mem.Allocator.Error![]const u64 {
    if (values.len == 0) return &.{};

    const entry = @import("generated_uniqueness_replay_contributions");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;

    const input: Input = .{
        .inputs = @ptrCast(&summaries.input),
        .contributions = storage.view(@FieldType(Input, "contributions"), values),
    };

    return entry.executeValue(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return replayError(err);
}

pub fn marks(allocator: std.mem.Allocator, summaries: *Summaries, values: []const Function.Mark) std.mem.Allocator.Error![]const u64 {
    if (values.len == 0) return &.{};

    const entry = @import("generated_uniqueness_replay_marks");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;

    const input: Input = .{
        .inputs = @ptrCast(&summaries.inputs),
        .outputs = @ptrCast(&summaries.outputs),
        .marks = storage.view(@FieldType(Input, "marks"), values),
    };

    return entry.executeValue(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return replayError(err);
}

fn replayError(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("summary replay failed: {s}", .{@errorName(err)});
}
