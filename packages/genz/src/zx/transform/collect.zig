const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const elements = @import("../state_value/elements.zig");
const Frame = @import("execution.zig").Frame;

pub fn transformCollectionElement(handle: *anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try elements.typeExpr(frame.lowering, frame.typeId()));
}

pub fn bindMapTransformResult(handle: *anyopaque, result: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(result)));
}

pub fn storeMapTransformValue(handle: *anyopaque, callback: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const value = try aggregate.bind(self, &frame.loop, @fromBackingInt(callback));

    return @backingInt(try elements.write(self, &frame.loop, frame.typeId(), value));
}

pub fn storeFilterTransformValue(handle: *anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const element = @backingInt(frame.transform.parameters[0]);
    const value = try self.builder.identifier(self.names[element]);
    const stored = try elements.write(self, &frame.loop, frame.typeId(), value);

    self.used[element] = true;

    return @backingInt(stored);
}

pub fn finishTransformCollection(handle: *anyopaque, start: u32, count: u32, result: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const owned = try @import("../state_value/list.zig").owned(self, frame.typeId(), @fromBackingInt(result), try self.builder.expression(.{ .boolean = false }));
    const body: node.Block = .{ .start = start, .len = count };

    return @backingInt(try aggregate.finishStored(self, body, owned, null));
}
