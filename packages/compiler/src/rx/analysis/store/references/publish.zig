const std = @import("std");
const zx = @import("zx");
const Store = @import("../../store.zig");
const memory = @import("zx").memory;
const rule = @import("generated_rx_store_reference_bindings");
const Input = std.meta.Child(rule.Input);
const Storage = @import("../references.zig").Storage;
const Object = Store.Object;

pub fn append(allocator: std.mem.Allocator, storage: std.mem.Allocator, scope: []const u8, objects: []const Object, bindings: *Storage) std.mem.Allocator.Error!bool {
    if (objects.len == 0) return true;

    const names = memory.borrowTextColumn("name", objects);
    const identities = memory.borrowTextColumn("identity", objects);
    const ids = memory.borrowNestedColumn(zx.ir.TypeId, &.{ "initial", "output_type" }, objects);

    const input: Input = .{
        .scope = scope,
        .objects = &.{ .names = @ptrCast(&names), .identities = @ptrCast(&identities), .ids = @ptrCast(&ids), .count = objects.len },
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    defer if (result.rows.len != 0) allocator.free(result.rows);

    if (!result.valid) {
        for (result.rows) |row| allocator.free(row.name);

        return false;
    }

    try bindings.ensureUnusedCapacity(storage, result.rows.len);

    for (result.rows) |row| {
        bindings.appendAssumeCapacity(.{
            .name = row.name,
            .path = row.path,
            .type_id = row.type_id,
        });
    }

    return true;
}
