const std = @import("std");
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Sequence = @import("../../../node/blocks.zig").Sequence;
const OriginBuffer = @import("../../construction/publication.zig").OriginBuffer;

pub fn emit(self: *Lower, sequence: *Sequence, value: ?node.ExpressionId) Lower.Error!node.Block {
    const entry = @import("generated_publish_statement_result");
    const Input = std.meta.Child(entry.Input);
    var origin: OriginBuffer = .{};

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .sequence = @ptrCast(sequence),
        .origin = @ptrCast(&origin),
        .value = if (value) |id| @backingInt(id) else null,
        .transaction = self.transaction(),
    };

    return @import("../publication.zig").span(self, entry, &input);
}
