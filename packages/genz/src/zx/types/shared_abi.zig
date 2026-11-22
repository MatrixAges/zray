const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const Cache = @import("cache.zig");
const generated = @import("generated_shared_abi");

pub fn build(self: *Lower, index: usize) Lower.Error!void {
    const Input = std.meta.Child(generated.Input);
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const input: Input = .{
        .types = &types,
        .names = self.type_names,
        .cached = view.slice(@FieldType(Input, "cached"), @as([]const node.ExpressionId, self.abi_types)),
        .root = @intCast(index),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    const output = zx.columns.invoke(generated.executeValue, buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const Output = std.meta.Child(generated.Output);

    return if (self.type_names != null) Cache.publish(self, Output, output, true) else Cache.publish(self, Output, output, false);
}
