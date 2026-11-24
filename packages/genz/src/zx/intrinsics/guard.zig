const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;

pub fn precondition(self: *Lower, body: *Sequence, predicate: node.ExpressionId) Lower.Error!void {
    const generated = @import("generated_precondition_guard");
    const Input = std.meta.Child(generated.Input);
    const bases = @import("../construction/context.zig").snapshot(std.meta.Child(@FieldType(Input, "bases")), self);
    const input: Input = .{ .bases = &bases, .predicate = @backingInt(predicate) };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = generated.executeIn(buffered.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    try @import("../construction/publication.zig").write(self, body, output, .Guard);
}
