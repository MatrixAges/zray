const Lower = @import("../lower.zig");
const elements = @import("../state_value/elements.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const borrow = @import("../expressions/evaluate.zig").borrow;

pub fn storeFilterTransformValue(frame: *anyopaque, sequence: *anyopaque, result_type: u32, symbol: u32, value: u32) Lower.Error!u32 {
    const self = borrow(frame);
    const body: *Sequence = @ptrCast(@alignCast(sequence));

    self.used[symbol] = true;

    return @backingInt(try elements.write(self, body, @fromBackingInt(result_type), @fromBackingInt(value)));
}
