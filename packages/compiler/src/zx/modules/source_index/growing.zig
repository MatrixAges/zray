const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const initial_capacity = 8;
const load_denominator = 4;
const capacity_growth = 2;

pub fn Map(comptime Value: type) type {
    return struct {
        const Self = @This();
        pub const empty: Self = .{};
        keys: std.ArrayList([]const u8) = .empty,
        values: std.ArrayList(Value) = .empty,
        buckets: []u64 = &.{},
        pub const Slot = struct { position: usize, existing: ?Value = null };
        pub const Position = struct { slot: usize, row: ?usize = null };

        pub fn get(self: *const Self, path: []const u8) ?Value {
            return self.probe(path).existing;
        }
        pub fn probe(self: *const Self, path: []const u8) Slot {
            const found = self.position(path);

            return .{ .position = found.slot, .existing = if (found.row) |row| self.values.items[row] else null };
        }
        pub fn getPtr(self: *const Self, path: []const u8) ?*Value {
            const row = self.position(path).row orelse return null;

            return &self.values.items[row];
        }
        pub fn position(self: *const Self, path: []const u8) Position {
            if (self.buckets.len == 0) return .{ .slot = 0 };

            const located = self.locate(path);

            return .{
                .slot = located.slot,
                .row = if (located.entry != 0) @intCast(located.entry - 1) else null,
            };
        }
        fn locate(self: *const Self, path: []const u8) Located {
            if (comptime generated) {
                const rule = @import("generated_byte_index_slot");

                const input: std.meta.Child(rule.Input) = .{
                    .keys = self.keys.items,
                    .rows = null,
                    .buckets = @ptrCast(&self.buckets),
                    .capacity = self.buckets.len,
                    .key = path,
                };

                var empty_buffer = std.heap.FixedBufferAllocator.init(&.{});
                const found = zx.columns.invoke(rule.executeValue, empty_buffer.allocator(), &input) catch unreachable;

                return .{ .slot = @intCast(found.slot), .entry = found.entry };
            }

            return seedProbe(self.keys.items, self.buckets, path);
        }
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, key: []const u8, slot: usize) std.mem.Allocator.Error!usize {
            if (comptime generated) {
                const rule = @import("generated_source_index_prepare");
                var columns: zx.memory.ColumnRangeGroup(2) = .{};
                var pending: []u64 = &.{};
                _ = columns.bind(&self.keys, 1, false);
                _ = columns.bind(&self.values, 1, false);

                errdefer allocator.free(pending);

                const input: std.meta.Child(rule.Input) = .{
                    .resource = @ptrCast(&allocator),
                    .columns = @ptrCast(columns.freeze().?),
                    .keys = @ptrCast(&self.keys.items),
                    .key = key,
                    .buckets = @ptrCast(&self.buckets),
                    .pending = @ptrCast(&pending),
                    .capacity = self.buckets.len,
                    .length = self.keys.items.len,
                    .maximum = std.math.maxInt(usize),
                    .slot = slot,
                };

                var empty_buffer = std.heap.FixedBufferAllocator.init(&.{});

                const selected = rule.executeIn(empty_buffer.allocator(), &input) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };

                return @intCast(selected orelse return error.OutOfMemory);
            }

            try self.keys.ensureUnusedCapacity(allocator, 1);
            try self.values.ensureUnusedCapacity(allocator, 1);

            const capacity = try seedCapacity(self.keys.items.len + 1, self.buckets.len);

            if (capacity == 0) return slot;

            const buckets = try allocator.alloc(u64, capacity);

            @memset(buckets, 0);
            self.rebuildSeed(buckets);
            allocator.free(self.buckets);

            self.buckets = buckets;

            return self.position(key).slot;
        }
        fn rebuildSeed(self: *const Self, buckets: []u64) void {
            for (self.keys.items, 1..) |key, entry| {
                buckets[seedProbe(self.keys.items, buckets, key).slot] = entry;
            }
        }
        pub fn append(self: *Self, slot: usize, key: []const u8, entry: Value) void {
            std.debug.assert(self.buckets[slot] == 0);

            if (comptime generated) {
                self.values.unusedCapacitySlice()[0] = entry;

                const rule = @import("generated_source_index_publish");
                const row: [][]const u8 = self.keys.unusedCapacitySlice()[0..1];
                const pointers = self.lengths();
                const counts: zx.memory.ColumnLengths = &pointers;

                const input: std.meta.Child(rule.Input) = .{
                    .buckets = @ptrCast(&self.buckets),
                    .key = key,
                    .target = @ptrCast(&row),
                    .lengths = @ptrCast(&counts),
                    .slot = slot,
                };

                var scratch = std.heap.FixedBufferAllocator.init(&.{});

                return rule.executeIn(scratch.allocator(), &input) catch unreachable;
            }

            self.keys.appendAssumeCapacity(key);
            self.values.appendAssumeCapacity(entry);

            self.buckets[slot] = self.keys.items.len;
        }
        /// Rebuilds the index after its owner compacts the retained rows in place.
        pub fn truncate(self: *Self, count: usize) void {
            if (comptime generated) {
                const rule = @import("generated_source_index_truncate");
                const pointers = self.lengths();
                const counts: zx.memory.ColumnLengths = &pointers;

                const input: std.meta.Child(rule.Input) = .{
                    .keys = self.keys.items[0..count],
                    .buckets = @ptrCast(&self.buckets),
                    .capacity = self.buckets.len,
                    .lengths = @ptrCast(&counts),
                };

                var scratch = std.heap.FixedBufferAllocator.init(&.{});

                return rule.executeIn(scratch.allocator(), &input) catch unreachable;
            }

            self.keys.shrinkRetainingCapacity(count);
            self.values.shrinkRetainingCapacity(count);
            @memset(self.buckets, 0);
            self.rebuildSeed(self.buckets);
        }
        fn lengths(self: *Self) [2]*usize {
            return .{ &self.keys.items.len, &self.values.items.len };
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.keys.deinit(allocator);
            self.values.deinit(allocator);
            allocator.free(self.buckets);
        }
    };
}

const Located = struct { slot: usize, entry: u64 };

fn seedCapacity(count: usize, previous: usize) std.mem.Allocator.Error!usize {
    const limit = previous - previous / load_denominator;

    if (count <= limit) return 0;
    if (previous == 0) return initial_capacity;

    return std.math.mul(usize, previous, capacity_growth) catch return error.OutOfMemory;
}

fn seedProbe(keys: []const []const u8, buckets: []const u64, path: []const u8) Located {
    const mask = buckets.len - 1;
    var slot: usize = @intCast(zx.bytes.hash(0, path) & mask);

    while (true) : (slot = (slot + 1) & mask) {
        const entry = buckets[slot];

        if (entry == 0 or zx.bytes.equal(keys[@intCast(entry - 1)], path)) return .{ .slot = slot, .entry = entry };
    }
}
