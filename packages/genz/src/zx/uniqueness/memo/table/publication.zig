const std = @import("std");
const reserve = @import("reserve.zig");
const entry = @import("generated_uniqueness_memo_store");
const Input = std.meta.Child(entry.Input);

pub fn StoreHost(comptime Entry: type) type {
    const State = std.meta.Child(@FieldType(Entry.zx_pending, "store_0"));
    const Value = std.meta.Child(State);

    return struct {
        const Self = @This();

        value: Value = .{ .row = 0, .bucket = null, .buckets = &.{}, .used = 0, .limit = 0, .changed = false },
        state: State = undefined,
        store_0: *State = undefined,
        pub fn init(self: *Self, used: u32, limit: u64, changed: bool) void {
            self.value = .{ .row = 0, .bucket = null, .buckets = &.{}, .used = used, .limit = limit, .changed = changed };
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
        initial_used: u32,
        changed: *bool,
        key: []const u8,
        value: []const u8,
        pub fn open(self: *Self, table: *Table, allocator: std.mem.Allocator, changed: *bool, key: []const u8, value: []const u8) void {
            self.* = .{
                .table = table,
                .allocator = allocator,
                .initial_used = @intCast(table.keys.items.len),
                .changed = changed,
                .key = key,
                .value = value,
            };
        }
        pub fn view(self: *Self, comptime View: type) View {
            return .{
                .keys = std.mem.sliceAsBytes(self.table.keys.items),
                .buckets = self.table.buckets,
                .current = self.initial_used,
                .limit = self.table.limit,
                .digest = self.key,
            };
        }
        pub fn finish(self: *Self, state: anytype) std.mem.Allocator.Error!void {
            if (!state.changed) return;

            const table = self.table;
            const limit: usize = @intCast(state.limit);

            const buckets = if (state.buckets.len == 0)
                table.buckets
            else
                try reserve.prepare(table, self.allocator, limit, state.buckets);

            const row: usize = @intCast(state.row);

            if (state.bucket) |bucket| {
                @memcpy(std.mem.asBytes(&table.keys.allocatedSlice()[row]), self.key);

                buckets[bucket] = @intCast(row + 1);
            }

            @memcpy(std.mem.asBytes(&table.values.allocatedSlice()[row]), self.value);

            if (state.buckets.len != 0) {
                self.allocator.free(table.buckets);

                table.buckets = buckets;
            }

            table.keys.items.len = state.used;
            table.values.items.len = state.used;
            table.limit = limit;
            self.changed.* = true;
        }
    };
}

pub fn put(table: anytype, allocator: std.mem.Allocator, key: anytype, value: anytype, changed: *bool) std.mem.Allocator.Error!u32 {
    var frame: Write(@TypeOf(table.*)) = undefined;
    var host: StoreHost(entry) = .{};

    frame.open(table, allocator, changed, key, std.mem.asBytes(value));
    host.init(frame.initial_used, 0, false);

    const input = frame.view(Input);
    var scratch_buf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const row = entry.executeIn(scratch.allocator(), &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => std.debug.panic("memo publication failed: {s}", .{@errorName(err)}),
    };

    try frame.finish(host.state.*);

    return @intCast(row);
}
