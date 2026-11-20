const std = @import("std");
const columns = @import("zx").columns;
const generated = @import("genz_options").generated_analysis;
const Digest = @import("../memo.zig").Digest;
const capacity = @import("generated_uniqueness_memo_capacity");
const exchange = @import("generated_uniqueness_memo_exchange");
const rebuild = @import("generated_uniqueness_memo_rebuild");
const Error = std.mem.Allocator.Error;

pub fn Table(comptime Value: type) type {
    if (!generated) return std.AutoHashMapUnmanaged(Digest, Value);

    return struct {
        const Self = @This();
        pub const empty: Self = .{};

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
            const row = self.rowFor(&key, null) orelse return null;

            return self.values.items[row];
        }
        pub fn getPtr(self: *Self, key: Digest) ?*Value {
            const row = self.rowFor(&key, null) orelse return null;

            return &self.values.items[row];
        }

        pub fn contains(self: *const Self, key: Digest) bool {
            return self.rowFor(&key, null) != null;
        }
        pub fn put(self: *Self, allocator: std.mem.Allocator, key: Digest, value: Value) Error!void {
            try self.ensureUnusedCapacity(allocator, 1);

            self.putAssumeCapacity(key, value);
        }

        pub fn putAssumeCapacity(self: *Self, key: Digest, value: Value) void {
            const insert: u32 = @intCast(self.keys.items.len);
            const row = self.rowFor(&key, insert);

            if (row) |existing| {
                self.values.items[existing] = value;

                return;
            }

            self.keys.appendAssumeCapacity(key);
            self.values.appendAssumeCapacity(value);
        }
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: u32) Error!void {
            const needed = std.math.add(u32, @intCast(self.keys.items.len), additional) catch return error.OutOfMemory;

            if (needed <= self.limit) return;

            const size = try capacity.executeValue(allocator, needed);
            const length = std.math.cast(usize, size.capacity) orelse return error.OutOfMemory;
            const limit: usize = @intCast(size.limit);

            try self.keys.ensureTotalCapacityPrecise(allocator, limit);
            try self.values.ensureTotalCapacityPrecise(allocator, limit);

            const buckets = try allocator.alloc(u32, length);

            @memset(buckets, 0);

            if (self.keys.items.len != 0) {
                const input: std.meta.Child(rebuild.Input) = .{
                    .keys = std.mem.sliceAsBytes(self.keys.items),
                    .buckets = @ptrCast(&buckets),
                    .capacity = length,
                };

                var scratch = std.heap.FixedBufferAllocator.init(&.{});

                _ = columns.invoke(rebuild.executeValue, scratch.allocator(), &input) catch unreachable;
            }

            allocator.free(self.buckets);

            self.buckets = buckets;
            self.limit = limit;
        }
        fn rowFor(self: *const Self, key: *const Digest, insert: ?u32) ?u32 {
            const input: std.meta.Child(exchange.Input) = .{
                .keys = std.mem.sliceAsBytes(self.keys.items),
                .buckets = @ptrCast(&self.buckets),
                .capacity = self.buckets.len,
                .key = key,
                .insert = insert,
            };

            var scratch = std.heap.FixedBufferAllocator.init(&.{});

            return columns.invoke(exchange.executeValue, scratch.allocator(), &input) catch unreachable;
        }
    };
}
