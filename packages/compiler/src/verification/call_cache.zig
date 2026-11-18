const std = @import("std");
const zx = @import("zx");
const terms = @import("terms.zig");
const Allocator = std.mem.Allocator;
pub const Cache = if (@import("parser_options").generated_parser) Source else Seed;

fn Lookup(comptime Key: type) type {
    return union(enum) { hit: terms.Evaluation, miss: Key };
}

const Source = struct {
    const Key = struct { target: u32, start: usize, length: usize, digest: u64 };

    const Context = struct {
        leaves: []const []const u8,
        pub fn hash(_: Context, key: Key) u64 {
            return key.digest;
        }
        pub fn eql(self: Context, left: Key, right: Key) bool {
            const rule = @import("generated_verification_call_equal");

            const input: std.meta.Child(rule.Input) = .{
                .left = &.{ .target = left.target, .terms = self.leaves[left.start..][0..left.length] },
                .right = &.{ .target = right.target, .terms = self.leaves[right.start..][0..right.length] },
            };

            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        }
    };
    rows: std.HashMapUnmanaged(Key, terms.Evaluation, Context, std.hash_map.default_max_load_percentage) = .empty,
    leaves: std.ArrayList([]const u8) = .empty,
    pub fn lookup(self: *Source, allocator: Allocator, target: u32, argument: terms.Value) Allocator.Error!Lookup(Key) {
        const start = self.leaves.items.len;

        errdefer self.leaves.shrinkRetainingCapacity(start);

        try self.collect(allocator, argument);

        const values = self.leaves.items[start..];
        const rule = @import("generated_verification_call_digest");
        const input: std.meta.Child(rule.Input) = .{ .target = target, .terms = values };
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const digest = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        const key = Key{ .target = target, .start = start, .length = values.len, .digest = digest };

        if (self.rows.getContext(key, .{ .leaves = self.leaves.items })) |result| {
            self.leaves.shrinkRetainingCapacity(start);

            return .{ .hit = result };
        }

        // Offsets survive pool growth while a nested call evaluates this miss.
        return .{ .miss = key };
    }
    fn collect(self: *Source, allocator: Allocator, value: terms.Value) Allocator.Error!void {
        switch (value) {
            .scalar => |leaf| try self.leaves.append(allocator, leaf),
            .fields => |fields| for (fields) |field| try self.collect(allocator, field),
        }
    }

    pub fn publish(self: *Source, allocator: Allocator, key: Key, result: terms.Evaluation) Allocator.Error!void {
        try self.rows.putContext(allocator, key, result, .{ .leaves = self.leaves.items });
    }
};

const Seed = struct {
    rows: std.StringHashMapUnmanaged(terms.Evaluation) = .empty,
    pub fn lookup(self: *Seed, allocator: Allocator, target: u32, argument: terms.Value) Allocator.Error!Lookup([]const u8) {
        const value = try std.json.Stringify.valueAlloc(allocator, argument, .{});
        const key = try std.fmt.allocPrint(allocator, "{d}:{s}", .{ target, value });

        return if (self.rows.get(key)) |result| .{ .hit = result } else .{ .miss = key };
    }
    pub fn publish(self: *Seed, allocator: Allocator, key: []const u8, result: terms.Evaluation) Allocator.Error!void {
        try self.rows.put(allocator, key, result);
    }
};
