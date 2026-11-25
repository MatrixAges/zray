const std = @import("std");
const ir = @import("zx").ir;
const missing = @import("../linking.zig").missing;

pub const Tail = struct {
    kinds: []u8,
    types: []u32,
    starts: []u64,
    ends: []u64,
    payloads: []u32,
    pub fn init(storage: *ir.ExpressionStorage, count: usize) Tail {
        return .{
            .kinds = std.mem.sliceAsBytes(storage.kinds.unusedCapacitySlice()[0..count]),
            .types = storage.types.unusedCapacitySlice()[0..count],
            .starts = storage.span_start.unusedCapacitySlice()[0..count],
            .ends = storage.span_end.unusedCapacitySlice()[0..count],
            .payloads = storage.payloads.unusedCapacitySlice()[0..count],
        };
    }
    pub fn view(self: *Tail, comptime Target: type) Target {
        return .{
            .kinds = @ptrCast(&self.kinds),
            .types = @ptrCast(&self.types),
            .starts = @ptrCast(&self.starts),
            .ends = @ptrCast(&self.ends),
            .payloads = @ptrCast(&self.payloads),
        };
    }
};

const header_columns = .{ "kinds", "payloads", "types", "span_start", "span_end" };

pub fn lengthSlots(storage: *ir.ExpressionStorage) [header_columns.len]*usize {
    var slots: [header_columns.len]*usize = undefined;

    inline for (header_columns, &slots) |name, *slot| slot.* = &@field(storage, name).items.len;

    return slots;
}

pub fn publishSeed(storage: *ir.ExpressionStorage, source: *const ir.ExpressionTable, rows: []const u32, count: usize) void {
    const kinds = storage.kinds.unusedCapacitySlice()[0..count];
    const types = storage.types.unusedCapacitySlice()[0..count];
    const starts = storage.span_start.unusedCapacitySlice()[0..count];
    const ends = storage.span_end.unusedCapacitySlice()[0..count];
    var target: usize = 0;

    for (rows, 0..) |row, index| {
        if (row == missing) continue;

        kinds[target] = source.kinds[index];
        types[target] = source.types[index];
        starts[target] = source.span_start[index];
        ends[target] = source.span_end[index];
        target += 1;
    }

    inline for (header_columns) |name| @field(storage, name).items.len += count;
}
