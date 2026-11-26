const std = @import("std");
const zx = @import("zx");
const generated = @import("generated_uniqueness_types_identity");
const Input = std.meta.Child(generated.Input);

pub fn build(value: zx.ir.TypeTable) [32]u8 {
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), value);

    const input: Input = .{
        .types = &types,
    };

    var pending: [4096]u8 = undefined;
    var backing = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer backing.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&pending, backing.allocator());
    const digest = generated.executeIn(scratch.allocator(), &input) catch |err| std.debug.panic("types identity failed: {s}", .{@errorName(err)});

    std.debug.assert(digest.len == 32);

    return digest[0..32].*;
}
