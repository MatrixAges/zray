const std = @import("std");
const zx = @import("zx");
const entry = @import("generated_uniqueness_memo_reserve");
const Input = std.meta.Child(entry.Input);

pub fn grow(table: anytype, allocator: std.mem.Allocator, additional: u32) std.mem.Allocator.Error!void {
    var keys = bind(&table.keys);
    var values = bind(&table.values);
    var buckets: []u32 = &.{};

    defer {
        sync(&table.keys, &keys);
        sync(&table.values, &values);
    }

    errdefer allocator.free(buckets);

    const input: Input = .{
        .owner = @ptrCast(&allocator),
        .keys = @ptrCast(&keys),
        .values = @ptrCast(&values),
        .buckets = @ptrCast(&buckets),
        .current = table.keys.items.len,
        .additional = additional,
    };

    const limit = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("memo table could not be rehashed: {s}", .{@errorName(err)}),
    };

    allocator.free(table.buckets);

    table.buckets = buckets;
    table.limit = @intCast(limit);
}

pub fn bind(list: anytype) zx.memory.RowBuffer {
    const Row = std.meta.Elem(@TypeOf(list.items));

    list.pointer_stability.assertUnlocked();

    return .{
        .bytes = std.mem.sliceAsBytes(list.allocatedSlice()),
        .stride = @sizeOf(Row),
        .alignment = .of(Row),
        .fields = &.{},
        .columns = &.{},
    };
}

pub fn sync(list: anytype, buffer: *const zx.memory.RowBuffer) void {
    const Row = std.meta.Elem(@TypeOf(list.items));
    const rows = buffer.rows(Row);

    list.items = rows[0..list.items.len];
    list.capacity = rows.len;
}
