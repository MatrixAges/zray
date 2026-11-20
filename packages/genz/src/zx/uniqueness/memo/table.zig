const std = @import("std");
const zx = @import("zx");
const columns = zx.columns;
const generated = @import("genz_options").generated_analysis;
const Digest = @import("../memo.zig").Digest;
const exchange = @import("generated_uniqueness_memo_exchange");
const touching = @import("generated_uniqueness_memo_touch");
const unused = @import("generated_uniqueness_memo_unused");
const publication = @import("table/publication.zig");
const reserve = @import("table/reserve.zig");
const Error = std.mem.Allocator.Error;

pub fn Table(comptime Value: type) type {
    if (!generated) return std.AutoHashMapUnmanaged(Digest, Value);

    return struct {
        const Self = @This();
        pub const empty: Self = .{};
        pub const Publication = publication.Frame;

        keys: std.ArrayList(Digest) = .empty,
        values: std.ArrayList(Value) = .empty,
        buckets: []u32 = &.{},
        limit: usize = 0,
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.keys.deinit(allocator);
            self.values.deinit(allocator);
            allocator.free(self.buckets);
        }

        pub fn get(self: *const Self, key: Digest) ?Value {
            const row = self.rowFor(&key) orelse return null;

            return self.values.items[row];
        }
        pub fn use(self: *Self, key: Digest) ?Value {
            const row = self.touch(key) orelse return null;

            return self.values.items[row];
        }
        pub fn keep(self: *Self, key: Digest) void {
            _ = self.touch(key);
        }

        pub fn contains(self: *const Self, key: Digest) bool {
            return self.rowFor(&key) != null;
        }
        pub fn put(self: *Self, allocator: std.mem.Allocator, key: Digest, value: Value) Error!void {
            try self.ensureUnusedCapacity(allocator, 1);

            publication.put(self, &key, &value);
        }
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: u32) Error!void {
            if (additional <= self.limit - self.keys.items.len) return;

            return reserve.grow(self, allocator, additional);
        }
        pub fn hasUnused(self: *const Self) bool {
            const used = zx.memory.borrowReadColumn(bool, "used", self.values.items);
            const input: std.meta.Child(unused.Input) = .{ .count = self.values.items.len, .used = @ptrCast(&used) };
            var scratch = std.heap.FixedBufferAllocator.init(&.{});

            return columns.invoke(unused.executeValue, scratch.allocator(), &input) catch unreachable;
        }
        fn touch(self: *Self, key: Digest) ?u32 {
            const used = publication.writeColumn(self.values.items, "used");

            const input: std.meta.Child(touching.Input) = .{
                .keys = std.mem.sliceAsBytes(self.keys.items),
                .buckets = @ptrCast(&self.buckets),
                .capacity = self.buckets.len,
                .key = &key,
                .used = @ptrCast(&used),
            };

            var scratch = std.heap.FixedBufferAllocator.init(&.{});

            return columns.invoke(touching.executeValue, scratch.allocator(), &input) catch unreachable;
        }
        fn rowFor(self: *const Self, key: *const Digest) ?u32 {
            const input: std.meta.Child(exchange.Input) = .{
                .keys = std.mem.sliceAsBytes(self.keys.items),
                .buckets = @ptrCast(&self.buckets),
                .capacity = self.buckets.len,
                .key = key,
                .insert = null,
            };

            var scratch = std.heap.FixedBufferAllocator.init(&.{});

            return columns.invoke(exchange.executeValue, scratch.allocator(), &input) catch unreachable;
        }
    };
}
