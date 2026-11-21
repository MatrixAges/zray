const std = @import("std");
const zx = @import("zx");
const reserve = @import("reserve.zig");
const entry = @import("generated_uniqueness_memo_store");
const Input = std.meta.Child(entry.Input);

pub fn Frame(comptime Index: type) type {
    return struct {
        const Self = @This();
        digests: zx.memory.RowBuffer,
        used: [1]u32,
        count: []u32,
        index: Index,
        pub fn open(self: *Self, table: anytype) void {
            const keys = table.keys.allocatedSlice();

            self.digests = reserve.bind(&table.keys);
            self.used = .{@intCast(table.keys.items.len)};
            self.count = &self.used;

            self.index = .{
                .keys = std.mem.sliceAsBytes(keys),
                .buckets = @ptrCast(&table.buckets),
                .capacity = table.buckets.len,
                .rows = @ptrCast(&self.digests),
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

pub fn put(table: anytype, allocator: std.mem.Allocator, key: anytype, value: anytype, changed: *bool) std.mem.Allocator.Error!u32 {
    var keys = reserve.bind(&table.keys);
    var values = reserve.bind(&table.values);
    var next_buckets: []u32 = &.{};
    var used = [1]u32{@intCast(table.keys.items.len)};
    const count: []u32 = &used;
    const dirty: []u8 = std.mem.asBytes(changed);

    defer {
        reserve.sync(&table.keys, &keys);
        reserve.sync(&table.values, &values);

        table.keys.items.len = used[0];
        table.values.items.len = used[0];
    }

    errdefer allocator.free(next_buckets);

    const input: Input = .{
        .keys = @ptrCast(&keys),
        .values = @ptrCast(&values),
        .buckets = @ptrCast(&table.buckets),
        .owner = @ptrCast(&allocator),
        .next_buckets = @ptrCast(&next_buckets),
        .current = used[0],
        .limit = table.limit,
        .used = @ptrCast(&count),
        .changed = @ptrCast(&dirty),
        .digest = key,
        .value = std.mem.asBytes(value),
    };

    const stored = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("memo publication failed: {s}", .{@errorName(err)}),
    };

    if (next_buckets.len != 0) {
        allocator.free(table.buckets);

        table.buckets = next_buckets;
    }

    table.limit = @intCast(stored.limit);

    return @intCast(stored.row);
}
