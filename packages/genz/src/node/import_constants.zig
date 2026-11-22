const std = @import("std");
const node = @import("../node.zig");
pub const Error = std.mem.Allocator.Error || error{InvalidAst};

/// Text must outlive the declaration list and every AST container subsequently built from it.
pub fn appendValuesBorrowingText(allocator: std.mem.Allocator, target: *std.ArrayList(node.Declaration), values: anytype) Error!void {
    if (values.len > std.math.maxInt(u32) - target.items.len) return error.OutOfMemory;
    try target.ensureUnusedCapacity(allocator, values.len);

    for (values) |value| {
        target.appendAssumeCapacity(.{ .constant = .{
            .name = value.name,
            .type_expr = if (value.type_expr) |id| @fromBackingInt(id) else null,
            .value = @fromBackingInt(value.value),
            .exported = value.exported,
        } });
    }
}
