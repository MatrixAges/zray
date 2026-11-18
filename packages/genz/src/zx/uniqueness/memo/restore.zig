const std = @import("std");
const zx = @import("zx");
const Growth = @import("../growth.zig");
const Summaries = @import("../summaries.zig");
const rows = @import("../row_output.zig");
const restore = @import("generated_uniqueness_memo_restore");
const Input = std.meta.Child(restore.Input);

pub fn apply(owner: std.mem.Allocator, source: []const u8, summaries: *Summaries, body: usize, callees: []const u32, demanded: bool, growth: *Growth.Rows) std.mem.Allocator.Error!bool {
    var normalized: rows.Normalized(Input) = undefined;
    var renewed: rows.Renewed(Input) = undefined;

    normalized.init();
    renewed.init();
    errdefer owner.free(normalized.rows());
    errdefer owner.free(renewed.rows());

    const input: Input = .{
        .state = &.{
            .source = source,
            .body = body,
            .callees = callees,
            .demanded = demanded,
            .input = @ptrCast(&summaries.input),
            .output = @ptrCast(&summaries.output),
            .inputs = @ptrCast(&summaries.inputs),
            .outputs = @ptrCast(&summaries.outputs),
        },
        .normalized = &.{ .storage = @ptrCast(&normalized.buffer), .columns = &normalized.view },
        .renewed = &.{ .storage = @ptrCast(&renewed.buffer), .columns = &renewed.view },
    };

    const valid = zx.columns.invoke(restore.executeValue, owner, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds, error.IntegerOverflow, error.Overflow => return false,
        else => std.debug.panic("memo state restoration failed: {s}", .{@errorName(err)}),
    };

    if (valid) growth.* = .{ .normalized = normalized.rows(), .renewed = renewed.rows() };

    return valid;
}
