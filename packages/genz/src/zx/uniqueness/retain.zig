const std = @import("std");
const zx = @import("zx");
const storage = zx.columns.storage;
const Function = @import("function.zig");
const Growth = @import("growth.zig");
const Memo = @import("memo.zig");
const Error = std.mem.Allocator.Error;

pub fn plan(owner: std.mem.Allocator, source: *const Function.Plan) Error!Function.Plan {
    const entry = @import("generated_uniqueness_retain_plan");

    const result = try retain(entry, owner, .{
        .flags = source.flags,
        .renewals = &source.renewals,
        .transfers = source.transfers,
        .slot_first = source.slot_first,
    });

    return Function.Plan.fromColumns(result);
}

pub fn growth(owner: std.mem.Allocator, source: Growth.Rows) Error!Growth.Rows {
    const entry = @import("generated_uniqueness_retain_growth");
    const Input = std.meta.Child(entry.Input);
    const Rows = std.meta.Child(@FieldType(Input, "normalized"));
    var normalized = rowBuffer(Growth.Normalized);
    var renewed = rowBuffer(Growth.Renewed);

    const input: Input = .{
        .normalized = &rowInput(Rows, &normalized, source.normalized),
        .renewed = &rowInput(Rows, &renewed, source.renewed),
    };

    try retain(entry, owner, input);

    return .{ .normalized = normalized.rows(Growth.Normalized), .renewed = renewed.rows(Growth.Renewed) };
}

pub fn marks(owner: std.mem.Allocator, source: []const Function.Mark) Error![]const Function.Mark {
    const entry = @import("generated_uniqueness_retain_rows");
    var buffer = rowBuffer(Function.Mark);

    try retain(entry, owner, rowInput(std.meta.Child(entry.Input), &buffer, source));

    return buffer.rows(Function.Mark);
}

fn rowBuffer(comptime Row: type) zx.memory.RowBuffer {
    return .{ .stride = @sizeOf(Row), .alignment = .of(Row), .fields = &.{}, .columns = &.{} };
}

fn rowInput(comptime Input: type, buffer: *zx.memory.RowBuffer, source: anytype) Input {
    return .{ .source = std.mem.sliceAsBytes(source), .target = @ptrCast(buffer), .count = source.len };
}

pub fn flow(owner: std.mem.Allocator, held: []const bool, text_held: []const bool, written: []const bool) Error!Memo.Flowed {
    const entry = @import("generated_uniqueness_retain_flow");
    const result = try retain(entry, owner, .{ .held = held, .text_held = text_held, .written = written });

    return .{ .held = result.held, .text_held = result.text_held, .written = result.written };
}

pub fn state(owner: std.mem.Allocator, source: []const u8) Error![]const u8 {
    return retain(@import("generated_uniqueness_retain_state"), owner, source);
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
