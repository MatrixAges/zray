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
    try bindings.ensureUnusedCapacity(storage, objects.len);

    const start = bindings.len;
    const end = start + objects.len;
    var output = bindings.slice();
    output.len = end;

    const names = memory.borrowTextColumn("name", objects);
    const identities = memory.borrowTextColumn("identity", objects);
    const ids = memory.borrowNestedColumn(zx.ir.TypeId, &.{ "initial", "output_type" }, objects);
    const published_names = output.items(.name)[start..];
    const published_paths = output.items(.path)[start..];
    const published_ids = output.items(.type_id)[start..];

    const input: Input = .{
        .scope = scope,
        .objects = &.{ .names = @ptrCast(&names), .identities = @ptrCast(&identities), .ids = @ptrCast(&ids), .count = objects.len },
        .bindings = &.{ .names = @ptrCast(&published_names), .paths = @ptrCast(&published_paths), .ids = @ptrCast(&published_ids) },
    };

    const valid = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (valid) bindings.len = end;

    return valid;
}
