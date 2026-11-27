const std = @import("std");
const zx = @import("zx");
const reserve = @import("reserve.zig");
const entry = @import("generated_uniqueness_memo_store");
const Input = std.meta.Child(entry.Input);

pub fn Frame(comptime Index: type) type {
    return struct {
        const Self = @This();
        digests: zx.memory.RowBuffer,
        index: Index,
        pub fn open(self: *Self, table: anytype) void {
            const keys = table.keys.allocatedSlice();

            self.digests = reserve.bind(&table.keys);

            self.index = .{
                .keys = std.mem.sliceAsBytes(keys),
                .buckets = @ptrCast(&table.buckets),
                .capacity = table.buckets.len,
                .rows = @ptrCast(&self.digests),
            };
        }
        pub fn finish(self: *const Self, table: anytype, used: u32) void {
            _ = self;
            table.keys.items.len = used;
            table.values.items.len = used;
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

pub fn StoreHost(comptime Entry: type) type {
    const State = std.meta.Child(@FieldType(Entry.zx_pending, "store_0"));
    const Value = std.meta.Child(State);

    return struct {
        const Self = @This();
        value: Value = .{ .used = 0, .limit = 0, .changed = false },
        state: State = undefined,
        store_0: *State = undefined,
        pub fn init(self: *Self, used: u32, limit: u64, changed: bool) void {
            self.value = .{ .used = used, .limit = limit, .changed = changed };
            self.state = &self.value;
            self.store_0 = &self.state;
        }

        pub fn commit(self: *Self, pending: anytype) error{}!void {
            if (pending.store_0) |next| self.store_0.* = next;
        }
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
        initial_used: u32,
        changed: *bool,
        pub fn open(self: *Self, table: *Table, allocator: std.mem.Allocator, changed: *bool) void {
            self.* = .{
                .table = table,
                .allocator = allocator,
                .keys = reserve.bind(&table.keys),
                .values = reserve.bind(&table.values),
                .initial_used = @intCast(table.keys.items.len),
                .changed = changed,
            };
        }
        pub fn view(self: *Self, comptime View: type, digest: []const u8) View {
            return .{
                .keys = @ptrCast(&self.keys),
                .values = @ptrCast(&self.values),
                .buckets = @ptrCast(&self.table.buckets),
                .owner = @ptrCast(&self.allocator),
                .owner_rows = @ptrCast(&self.allocator),
                .next_buckets = @ptrCast(&self.next_buckets),
                .current = self.initial_used,
                .limit = self.table.limit,
                .digest = digest,
            };
        }

        pub fn finish(self: *Self, state: anytype) void {
            const table = self.table;

            reserve.sync(&table.keys, &self.keys);
            reserve.sync(&table.values, &self.values);

            table.keys.items.len = state.used;
            table.values.items.len = state.used;

            if (state.changed) self.changed.* = true;

            if (state.limit == 0) {
                self.allocator.free(self.next_buckets);

                return;
            }

            if (self.next_buckets.len != 0) {
                self.allocator.free(table.buckets);

                table.buckets = self.next_buckets;
            }

            table.limit = @intCast(state.limit);
        }
    };
}

pub fn put(table: anytype, allocator: std.mem.Allocator, key: anytype, value: anytype, changed: *bool) std.mem.Allocator.Error!u32 {
    var frame: Write(@TypeOf(table.*)) = undefined;
    var host: StoreHost(entry) = .{};

    frame.open(table, allocator, changed);
    host.init(frame.initial_used, 0, false);
    defer frame.finish(host.state.*);

    const view = frame.view(Fields, key);

    var input: Input = undefined;

    inline for (@typeInfo(Fields).@"struct".field_names) |name| @field(input, name) = @field(view, name);

    input.value = std.mem.asBytes(value);

    const source: *const Input = &input;
    var scratch_buf: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);

    const row = entry.executeIn(scratch.allocator(), source, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("memo publication failed: {s}", .{@errorName(err)}),
    };

    return @intCast(row);
}

const Fields = struct {
    buckets: @FieldType(Input, "buckets"),
    current: @FieldType(Input, "current"),
    digest: @FieldType(Input, "digest"),
    keys: @FieldType(Input, "keys"),
    limit: @FieldType(Input, "limit"),
    next_buckets: @FieldType(Input, "next_buckets"),
    owner: @FieldType(Input, "owner"),
    owner_rows: @FieldType(Input, "owner_rows"),
    values: @FieldType(Input, "values"),
};
