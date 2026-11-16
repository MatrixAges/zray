const std = @import("std");
const zx = @import("zx");
const Growth = @import("../growth.zig");
const borrowColumn = @import("zx").memory.borrowWriteColumn;
const generated = @import("generated_uniqueness_growth_snapshot");
const Input = std.meta.Child(generated.Input);
const Columns = std.meta.Child(@FieldType(Input, "normalized_target"));
const Entries = @FieldType(Input, "normalized");

pub fn publish(owner: std.mem.Allocator, normalized_entries: anytype, renewed_entries: @TypeOf(normalized_entries)) std.mem.Allocator.Error!Growth.Rows {
    const normalized = try owner.alloc(Growth.Normalized, normalized_entries.len);

    errdefer owner.free(normalized);

    const renewed = try owner.alloc(Growth.Renewed, renewed_entries.len);

    errdefer owner.free(renewed);

    const ids = borrowColumn(u32, "id", normalized);
    const normalized_wants = borrowColumn(u8, "want", normalized);
    const keys = borrowColumn(u64, "key", renewed);
    const renewed_wants = borrowColumn(u8, "want", renewed);
    const first: Columns = .{ .keys = @ptrCast(&ids), .wants = @ptrCast(&normalized_wants) };
    const second: Columns = .{ .keys = @ptrCast(&keys), .wants = @ptrCast(&renewed_wants) };

    const input: Input = .{
        .normalized = zx.columns.slice(Entries, normalized_entries),
        .renewed = zx.columns.slice(Entries, renewed_entries),
        .normalized_target = &first,
        .renewed_target = &second,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("growth snapshot publication failed: {s}", .{@errorName(err)}),
    };

    return .{ .normalized = normalized, .renewed = renewed };
}
