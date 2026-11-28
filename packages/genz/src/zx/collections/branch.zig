const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const evaluation = @import("../expressions/evaluate.zig");
const Error = Lower.Error;

pub fn collectionCompare(frame: *anyopaque, source_type: u32) Error![]const u8 {
    const self = evaluation.borrow(frame);
    const child = self.program.typeOf(@fromBackingInt(source_type)).list;
    var found = false;

    for (self.comparisons.items) |previous| {
        if (previous == child) found = true;
    }

    if (!found) try self.comparisons.append(self.allocator, child);

    return @import("../comparison.zig").name(self, child);
}

pub fn emitCollectionPop(
    frame: *anyopaque,
    body: *anyopaque,
    id: u32,
    source_type: u32,
    result_type: u32,
    items: u32,
    value: u32,
    header: u32,
    element: u32,
    length: u32,
) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try @import("pop.zig").lower(lowering, sequence, .{
        .type_id = @fromBackingInt(source_type),
        .result_type = @fromBackingInt(result_type),
        .items = @fromBackingInt(items),
        .value = @fromBackingInt(value),
        .header = @fromBackingInt(header),
        .element = @fromBackingInt(element),
        .length = @fromBackingInt(length),
        .retract = lowering.plan.get(@fromBackingInt(id)).retract,
    }));
}
