const std = @import("std");
const zx = @import("zx");
const Growth = @import("../growth.zig");
const rows = @import("../row_output.zig");
const generated = @import("generated_uniqueness_growth_snapshot");
const Input = std.meta.Child(generated.Input);
const Targets = std.meta.Child(@FieldType(Input, "targets"));
const Entries = @FieldType(Input, "normalized");

pub fn publish(owner: std.mem.Allocator, normalized_entries: anytype, renewed_entries: @TypeOf(normalized_entries)) std.mem.Allocator.Error!Growth.Rows {
    var normalized: rows.Normalized(Targets) = undefined;
    var renewed: rows.Renewed(Targets) = undefined;

    normalized.init();
    renewed.init();
    errdefer owner.free(normalized.rows());
    errdefer owner.free(renewed.rows());

    const input: Input = .{
        .normalized = zx.columns.slice(Entries, normalized_entries),
        .renewed = zx.columns.slice(Entries, renewed_entries),
        .targets = &.{
            .normalized = &.{ .storage = @ptrCast(&normalized.buffer), .columns = &normalized.view },
            .renewed = &.{ .storage = @ptrCast(&renewed.buffer), .columns = &renewed.view },
        },
    };

    zx.columns.invoke(generated.executeValue, owner, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("growth snapshot publication failed: {s}", .{@errorName(err)}),
    };

    return .{ .normalized = normalized.rows(), .renewed = renewed.rows() };
}
