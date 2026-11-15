const std = @import("std");
const zx = @import("zx");
const expressions = @import("frontend").expressions;
const memory = @import("zxc_standard").memory;
const entry = @import("generated_rx_publish_type_imports");
const Input = std.meta.Child(entry.Input);
const Qualified = std.meta.Child(@typeInfo(@FieldType(Input, "qualified")).optional.child);
const Export = zx.ir.Export;
pub const Target = struct { alias: []const u8, rows: []Export };

pub fn append(allocator: std.mem.Allocator, value_allocator: std.mem.Allocator, exports: []const Export, kinds: []const u8, visible: *expressions.BindingStorage, target: ?Target) std.mem.Allocator.Error!void {
    const rows = memory.borrowNamedRows("type_id", exports);
    const destination: []memory.NamedId = if (target) |output| memory.borrowNamedRows("type_id", output.rows) else &.{};

    const qualified: Qualified = .{
        .alias = if (target) |output| output.alias else "",
        .rows = @ptrCast(&destination),
    };

    var cursor: u64 = 0;

    while (cursor < rows.len) {
        var reserved = visible.slice();
        reserved.len = reserved.capacity;
        const names = reserved.items(.name)[visible.len..];
        const ids = reserved.items(.type_id)[visible.len..];

        const input: Input = .{
            .rows = @ptrCast(&rows),
            .length = rows.len,
            .kinds = kinds,
            .qualified = if (target != null) &qualified else null,
            .values = &.{ .names = @ptrCast(&names), .ids = @ptrCast(&ids), .capacity = ids.len },
            .next = cursor,
        };

        const result = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.IndexOutOfBounds => unreachable,
        };

        visible.len += @intCast(result.visible);
        cursor = result.next;

        if (cursor < rows.len) try visible.ensureUnusedCapacity(value_allocator, 1);
    }
}
