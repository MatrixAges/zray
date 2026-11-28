const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const failure = @import("../construction/publication.zig").failure;
const Sequence = @import("../../node/blocks.zig").Sequence;

pub const Guard = struct { condition: node.ExpressionId, fallback: node.ExpressionId };

pub fn bind(self: *Lower, body: *Sequence, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const entry = @import("generated_operand_binding");

    const input: std.meta.Child(entry.Input) = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .sequence = @ptrCast(body),
        .value = @backingInt(value),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .serial = self.serial,
    };

    return execute(self, entry, &input);
}

pub fn finish(self: *Lower, body: node.Block, value: node.ExpressionId, guard: ?Guard) Lower.Error!node.ExpressionId {
    const entry = @import("generated_result_block");

    const input: std.meta.Child(entry.Input) = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .block = &.{
            .value = @backingInt(value),
            .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
            .statement_base = body.start,
            .body_count = body.len,
            .serial = self.serial,
        },
        .guard = if (guard) |check| &.{
            .condition = @backingInt(check.condition),
            .yes = @backingInt(value),
            .no = @backingInt(check.fallback),
        } else null,
    };

    return execute(self, entry, &input);
}

fn execute(self: *Lower, comptime entry: type, input: entry.Input) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(buffered.allocator(), input) catch |err| return failure(err);

    return @fromBackingInt(if (entry.Output == u32) result else result.root);
}
