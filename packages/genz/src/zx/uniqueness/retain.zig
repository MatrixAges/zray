const std = @import("std");
const zx = @import("zx");
const storage = zx.columns.storage;
const Function = @import("function.zig");
const Memo = @import("memo.zig");
const Error = std.mem.Allocator.Error;

pub fn plan(owner: std.mem.Allocator, source: *const Function.Plan) Error!Function.Plan {
    return (try @import("program/visit/adopt_plan.zig").run(owner, source, null)).plan();
}

pub fn marks(owner: std.mem.Allocator, source: []const Function.Mark) Error![]const Function.Mark {
    const entry = @import("generated_uniqueness_retain_rows");
    var buffer = zx.memory.RowBuffer.empty(Function.Mark);

    try retain(entry, owner, rowInput(std.meta.Child(entry.Input), &buffer, source, &owner));

    return buffer.rows(Function.Mark);
}

pub fn rowInput(comptime Input: type, buffer: *zx.memory.RowBuffer, source: anytype, owner: *const std.mem.Allocator) Input {
    return .{ .source = std.mem.sliceAsBytes(source), .target = @ptrCast(buffer), .count = source.len, .owner = @ptrCast(owner) };
}

pub fn flow(owner: std.mem.Allocator, held: []const bool, text_held: []const bool, written: []const bool) Error!Memo.Flowed {
    const entry = @import("generated_uniqueness_retain_flow");
    const result = try retain(entry, owner, .{ .held = held, .text_held = text_held, .written = written });

    return .{ .held = result.held, .text_held = result.text_held, .written = result.written };
}

fn retain(comptime entry: type, owner: std.mem.Allocator, source: anytype) Error!@typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload {
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer and @typeInfo(Parameter).pointer.size == .one;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const input = storage.view(Input, source);

    return entry.executeValue(owner, if (indirect) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("ownership record retention failed: {s}", .{@errorName(err)}),
    };
}
