const std = @import("std");
const zx = @import("zx");
const entry = @import("generated_uniqueness_memo_publish");
const Input = std.meta.Child(entry.Input);

pub fn Frame(comptime Index: type) type {
    const Lookup = std.meta.Child(@FieldType(Index, "lookup"));

    return struct {
        const Self = @This();
        digests: zx.memory.WriteColumn,
        used: [1]u32,
        count: []u32,
        lookup: Lookup,
        index: Index,
        pub fn open(self: *Self, table: anytype) void {
            const keys = table.keys.allocatedSlice();

            self.digests = writeColumn(keys, null);
            self.used = .{@intCast(table.keys.items.len)};
            self.count = &self.used;

            self.lookup = .{
                .keys = std.mem.sliceAsBytes(keys),
                .buckets = @ptrCast(&table.buckets),
                .capacity = table.buckets.len,
            };

            self.index = .{
                .lookup = &self.lookup,
                .keys = @ptrCast(&self.digests),
                .used = @ptrCast(&self.count),
            };
        }

        pub fn finish(self: *const Self, table: anytype) void {
            table.keys.items.len = self.used[0];
            table.values.items.len = self.used[0];
        }
    };
}

pub fn writeColumn(items: anytype, comptime field: ?[]const u8) zx.memory.WriteColumn {
    const Row = std.meta.Elem(@TypeOf(items));
    const stride = @sizeOf(Row);
    const offset = if (field) |name| @offsetOf(Row, name) else 0;
    const width = if (field) |name| @sizeOf(@FieldType(Row, name)) else stride;
    const bytes: [*]u8 = @ptrCast(items.ptr);

    return .{
        .items = if (items.len == 0) bytes else bytes + offset,
        .count = items.len,
        .stride = stride,
        .width = width,
    };
}

pub fn put(table: anytype, key: anytype, value: anytype) void {
    var frame: Frame(std.meta.Child(@FieldType(Input, "index"))) = undefined;

    frame.open(table);

    const values = writeColumn(table.values.allocatedSlice(), null);

    const input: Input = .{
        .index = &frame.index,
        .digest = key,
        .values = @ptrCast(&values),
        .value = std.mem.asBytes(value),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;
    frame.finish(table);
}
