const std = @import("std");
const zx = @import("zx");
const terms = @import("terms.zig");
const Allocator = std.mem.Allocator;
pub const Cache = Source;

fn Lookup(comptime Key: type) type {
    return union(enum) { hit: terms.Evaluation, miss: Key };
}

const Source = struct {
    pub const Key = struct { target: u32, start: usize, length: usize, digest: u64 };

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

        var frame: Probe = .{ .cache = self, .allocator = allocator };
        const entry = @import("generated_lookup_symbolic_call");

        const input: std.meta.Child(entry.Input) = .{
            .key = @ptrCast(&frame),
            .argument = @ptrCast(&argument),
            .start = start,
            .target = target,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        entry.executeIn(empty.allocator(), &input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        return frame.result;
    }
    pub fn publish(self: *Source, allocator: Allocator, key: Key, result: terms.Evaluation) Allocator.Error!void {
        try self.rows.putContext(allocator, key, result, .{ .leaves = self.leaves.items });
    }
};

const Probe = struct {
    cache: *Source,
    allocator: Allocator,
    result: Lookup(Source.Key) = undefined,
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn appendSymbolicCallKey(handle: *const anyopaque, text: []const u8) Allocator.Error!void {
    const probe = Probe.borrow(handle);

    try probe.cache.leaves.append(probe.allocator, text);
}

pub fn symbolicCallKeyTerms(handle: *const anyopaque, start: u64) []const []const u8 {
    return Probe.borrow(handle).cache.leaves.items[@intCast(start)..];
}

pub fn probeSymbolicCallKey(handle: *const anyopaque, target: u32, start: u64, count: u64, digest: u64) bool {
    const probe = Probe.borrow(handle);
    // Offsets survive pool growth while a nested call evaluates this miss.
    const key: Source.Key = .{ .target = target, .start = @intCast(start), .length = @intCast(count), .digest = digest };

    if (probe.cache.rows.getContext(key, .{ .leaves = probe.cache.leaves.items })) |value| {
        probe.result = .{ .hit = value };

        return true;
    }

    probe.result = .{ .miss = key };

    return false;
}

pub fn rewindSymbolicCallKey(handle: *const anyopaque, start: u64) void {
    Probe.borrow(handle).cache.leaves.shrinkRetainingCapacity(@intCast(start));
}
