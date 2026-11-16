const std = @import("std");
const zx = @import("zx");
const memory = @import("zx").memory;
const Slot = @import("genz").gateway.Slot;
const rule = @import("generated_gateway_slots");

pub fn create(allocator: std.mem.Allocator, indices: []const u64, writable: []const bool) std.mem.Allocator.Error![]const Slot {
    const slots = try allocator.alloc(Slot, indices.len);

    errdefer allocator.free(slots);

    const wide = @sizeOf(usize) == @sizeOf(u64);
    const slot = memory.borrowWriteColumn(if (wide) u64 else u32, "index", slots);
    const access = memory.borrowWriteColumn(u8, "writable", slots);

    const input: std.meta.Child(rule.Input) = .{
        .indices = indices,
        .writable = writable,
        .wide = wide,
        .slot = @ptrCast(&slot),
        .access = @ptrCast(&access),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return slots;
}
