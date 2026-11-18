const std = @import("std");

pub fn steps(comptime rule: type, comptime input: rule.Input) []const std.meta.Child(rule.Output) {
    const Step = std.meta.Child(rule.Output);

    return &struct {
        const order = blk: {
            var storage: [@typeInfo(Step).@"enum".field_names.len * @sizeOf(Step)]u8 = undefined;
            var scratch = std.heap.FixedBufferAllocator.init(&storage);
            const sequence = rule.executeValue(scratch.allocator(), input) catch unreachable;

            break :blk sequence[0..sequence.len].*;
        };
    }.order;
}
