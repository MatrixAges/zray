const std = @import("std");
const ir = @import("zx").ir;
const missing = @import("../linking.zig").missing;

pub fn append(storage: *ir.ExpressionStorage, row: anytype) void {
    const Kind = std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds"));

    storage.kinds.appendAssumeCapacity(@fromBackingInt(@as(@typeInfo(Kind).@"enum".tag_type, @intCast(row.kind))));
    storage.types.appendAssumeCapacity(row.type_id);
    storage.span_start.appendAssumeCapacity(row.start);
    storage.span_end.appendAssumeCapacity(row.end);
    storage.payloads.appendAssumeCapacity(row.payload);
}

const header_columns = .{ "kinds", "payloads", "types", "span_start", "span_end" };

pub fn commit(storage: *ir.ExpressionStorage, source: *const ir.ExpressionTable, ranges: anytype, count: usize) void {
    for (ranges) |range| {
        const start: usize = @intCast(range.start);
        const end: usize = @intCast(range.end);

        inline for (.{ "kinds", "types", "span_start", "span_end" }) |name| {
            @field(storage, name).appendSliceAssumeCapacity(@field(source, name)[start..end]);
        }
    }

    storage.payloads.items.len += count;
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
