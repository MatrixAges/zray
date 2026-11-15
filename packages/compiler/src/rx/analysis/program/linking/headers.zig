const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../builder.zig");
const operands = @import("operands.zig");
const missing = @import("../linking.zig").missing;
const generated = @import("rx_options").generated_graph;

pub const Tail = struct {
    kinds: []u8,
    types: []u32,
    starts: []u64,
    ends: []u64,
    payloads: []u32,
    pub fn init(storage: *ir.ExpressionStorage) Tail {
        return .{
            .kinds = std.mem.sliceAsBytes(storage.kinds.unusedCapacitySlice()[0..1]),
            .types = storage.types.unusedCapacitySlice()[0..1],
            .starts = storage.span_start.unusedCapacitySlice()[0..1],
            .ends = storage.span_end.unusedCapacitySlice()[0..1],
            .payloads = storage.payloads.unusedCapacitySlice()[0..1],
        };
    }
    pub fn view(self: *const Tail, comptime Target: type) Target {
        return .{
            .kinds = @ptrCast(&self.kinds),
            .types = @ptrCast(&self.types),
            .starts = @ptrCast(&self.starts),
            .ends = @ptrCast(&self.ends),
            .payloads = @ptrCast(&self.payloads),
        };
    }
};

pub fn commit(storage: *ir.ExpressionStorage, count: usize) void {
    inline for (.{ "kinds", "payloads", "types", "span_start", "span_end" }) |name| {
        @field(storage, name).items.len += count;
    }
}

pub fn publish(storage: *ir.ExpressionStorage, source: *const ir.ExpressionTable, rows: []const u32, count: usize) Builder.Error!void {
    const kinds = storage.kinds.unusedCapacitySlice()[0..count];
    const types = storage.types.unusedCapacitySlice()[0..count];
    const starts = storage.span_start.unusedCapacitySlice()[0..count];
    const ends = storage.span_end.unusedCapacitySlice()[0..count];

    if (comptime generated) {
        const rule = @import("generated_rx_link_headers");
        const target_kinds = std.mem.sliceAsBytes(kinds);
        const target_types = std.mem.sliceAsBytes(types);
        const target_starts = std.mem.sliceAsBytes(starts);
        const target_ends = std.mem.sliceAsBytes(ends);

        try operands.invoke(rule, .{
            .rows = rows,
            .kinds = std.mem.sliceAsBytes(source.kinds),
            .types = std.mem.sliceAsBytes(source.types),
            .starts = std.mem.sliceAsBytes(source.span_start),
            .ends = std.mem.sliceAsBytes(source.span_end),
            .target_kinds = @ptrCast(&target_kinds),
            .target_types = @ptrCast(&target_types),
            .target_starts = @ptrCast(&target_starts),
            .target_ends = @ptrCast(&target_ends),
            .type_width = @sizeOf(u32),
            .span_width = @sizeOf(u64),
        });
    } else {
        var target: usize = 0;

        for (rows, 0..) |row, index| {
            if (row == missing) continue;

            kinds[target] = source.kinds[index];
            types[target] = source.types[index];
            starts[target] = source.span_start[index];
            ends[target] = source.span_end[index];
            target += 1;
        }
    }

    commit(storage, count);
}
