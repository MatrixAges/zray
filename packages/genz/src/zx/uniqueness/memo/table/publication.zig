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

pub fn Write(comptime Table: type) type {
    return struct {
        const Self = @This();
        table: *Table,
        allocator: std.mem.Allocator,
        keys: zx.memory.RowBuffer,
        values: zx.memory.RowBuffer,
        next_buckets: []u32 = &.{},
        used: [1]u32,
        count: []u32,
        dirty: []u8,
        published: [1]u64 = .{0},
        limit: []u64,
        pub fn open(self: *Self, table: *Table, allocator: std.mem.Allocator, changed: *bool) void {
            self.* = .{
                .table = table,
                .allocator = allocator,
                .keys = reserve.bind(&table.keys),
                .values = reserve.bind(&table.values),
                .used = .{@intCast(table.keys.items.len)},
                .count = &self.used,
                .dirty = std.mem.asBytes(changed),
                .limit = &self.published,
            };
        }
        pub fn view(self: *const Self, comptime View: type, digest: []const u8) View {
            return .{
                .keys = @ptrCast(&self.keys),
                .values = @ptrCast(&self.values),
                .buckets = @ptrCast(&self.table.buckets),
                .owner = @ptrCast(&self.allocator),
                .next_buckets = @ptrCast(&self.next_buckets),
                .current = self.used[0],
                .limit = self.table.limit,
                .used = @ptrCast(&self.count),
                .changed = @ptrCast(&self.dirty),
                .digest = digest,
            };
        }

        pub fn finish(self: *Self) void {
            const table = self.table;

            reserve.sync(&table.keys, &self.keys);
            reserve.sync(&table.values, &self.values);

            table.keys.items.len = self.used[0];
            table.values.items.len = self.used[0];

            if (self.published[0] == 0) {
                self.allocator.free(self.next_buckets);

                return;
            }

            if (self.next_buckets.len != 0) {
                self.allocator.free(table.buckets);

                table.buckets = self.next_buckets;
            }

            table.limit = @intCast(self.published[0]);
        }
    };
}

pub fn put(table: anytype, allocator: std.mem.Allocator, key: anytype, value: anytype, changed: *bool) std.mem.Allocator.Error!u32 {
    var frame: Write(@TypeOf(table.*)) = undefined;

    frame.open(table, allocator, changed);
    defer frame.finish();

    const view = frame.view(Fields, key);

    var input: Input = undefined;

    inline for (@typeInfo(Fields).@"struct".field_names) |name| @field(input, name) = @field(view, name);

    input.value = std.mem.asBytes(value);

    const source: *const Input = &input;

    const stored = zx.columns.invoke(entry.executeValue, allocator, source) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("memo publication failed: {s}", .{@errorName(err)}),
    };

    frame.published[0] = stored.limit;

    return @intCast(stored.row);
}

const Fields = struct {
    buckets: @FieldType(Input, "buckets"),
    changed: @FieldType(Input, "changed"),
    current: @FieldType(Input, "current"),
    digest: @FieldType(Input, "digest"),
    keys: @FieldType(Input, "keys"),
    limit: @FieldType(Input, "limit"),
    next_buckets: @FieldType(Input, "next_buckets"),
    owner: @FieldType(Input, "owner"),
    used: @FieldType(Input, "used"),
    values: @FieldType(Input, "values"),
};
