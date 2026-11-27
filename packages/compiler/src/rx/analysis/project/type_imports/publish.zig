const std = @import("std");
const expressions = @import("frontend").expressions;
const memory = @import("zx").memory;
const entry = @import("generated_rx_publish_type_imports");
const Export = @import("zx").ir.Export;

pub const Target = struct { alias: []const u8, rows: []Export };

pub fn append(allocator: std.mem.Allocator, value_allocator: std.mem.Allocator, exports: []const Export, kinds: []const u8, visible: *expressions.BindingStorage, target: ?Target) std.mem.Allocator.Error!void {
    if (exports.len == 0) return;

    const rows = memory.borrowNamedRows("type_id", exports);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [4096]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const result = entry.executeIn(scratch.allocator(), &.{
        .rows = @ptrCast(&rows),
        .length = rows.len,
        .kinds = kinds,
        .alias = if (target) |output| output.alias else null,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (target) |output| {
        for (output.rows, result.qualified) |*slot, row| {
            slot.* = .{ .name = try allocator.dupe(u8, row.name), .type_id = @fromBackingInt(row.id) };
        }
    }

    if (result.visible.len == 0) return;
    try visible.ensureUnusedCapacity(value_allocator, result.visible.len);

    for (result.visible) |row| {
        visible.appendAssumeCapacity(.{
            .name = if (target != null) try value_allocator.dupe(u8, row.name) else row.name,
            .type_id = @fromBackingInt(row.id),
        });
    }
}
