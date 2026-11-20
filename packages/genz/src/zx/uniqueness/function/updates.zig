const std = @import("std");
const Function = @import("../function.zig");
const Summaries = @import("../summaries.zig");
const storage = @import("zx").columns.storage;

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

fn replayError(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("summary replay failed: {s}", .{@errorName(err)});
}
