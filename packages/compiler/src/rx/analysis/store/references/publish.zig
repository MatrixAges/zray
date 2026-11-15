const std = @import("std");
const zx = @import("zx");
const Store = @import("../../store.zig");
const memory = @import("zxc_standard").memory;
const rule = @import("generated_rx_store_reference_bindings");
const Input = std.meta.Child(rule.Input);
const Storage = @import("../references.zig").Storage;
const Object = Store.Object;
const id_size = @sizeOf(u32);
const id_offset = @divExact(@offsetOf(Object, "initial") + @offsetOf(zx.ir.Program, "output_type"), id_size);
const id_stride = @divExact(@sizeOf(Object), id_size);

pub fn append(allocator: std.mem.Allocator, storage: std.mem.Allocator, scope: []const u8, objects: []const Object, bindings: *Storage) std.mem.Allocator.Error!bool {
    if (objects.len == 0) return true;
    try bindings.ensureUnusedCapacity(storage, objects.len);

    const start = bindings.len;
    const end = start + objects.len;
    var output = bindings.slice();
    output.len = end;

    const names = memory.borrowTextColumn("name", objects);
    const identities = memory.borrowTextColumn("identity", objects);
    const ids = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(objects))[id_offset..];
    const published_names = output.items(.name)[start..];
    const published_paths = output.items(.path)[start..];
    const published_ids = output.items(.type_id)[start..];

    const input: Input = .{
        .scope = scope,
        .objects = &.{ .names = @ptrCast(&names), .identities = @ptrCast(&identities), .ids = ids, .stride = id_stride, .count = objects.len },
        .bindings = &.{ .names = @ptrCast(&published_names), .paths = @ptrCast(&published_paths), .ids = @ptrCast(&published_ids) },
    };

    const valid = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.InvalidUtf8 => return false,
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (valid) bindings.len = end;

    return valid;
}
