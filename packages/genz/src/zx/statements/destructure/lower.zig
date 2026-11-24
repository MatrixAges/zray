const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");

pub fn publish(self: *Lower, binding: @FieldType(ir.StatementRow, "destructure")) Lower.Error!node.Block {
    const entry = @import("generated_publish_destructure");
    const Input = std.meta.Child(entry.Input);
    const value = @backingInt(binding.value);

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .serial = self.serial,
        .value = value,
        .capture = self.program.expressions.kinds[value] == .Capture,
        .symbols = binding.symbols.values[0..binding.symbols.len],
        .names = self.names,
        .used = self.used,
    };

    return @import("../publication.zig").span(self, entry, &input);
}
