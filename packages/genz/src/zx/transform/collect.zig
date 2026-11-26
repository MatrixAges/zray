const Lower = @import("../lower.zig");
const elements = @import("../state_value/elements.zig");
const Frame = @import("execution.zig").Frame;

pub fn storeMapTransformValue(handle: *anyopaque, value: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try elements.write(frame.lowering, &frame.loop, frame.typeId(), @fromBackingInt(value)));
}
