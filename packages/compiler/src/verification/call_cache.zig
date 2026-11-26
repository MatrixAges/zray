const std = @import("std");
const zx = @import("zx");
const terms = @import("terms.zig");
const Allocator = std.mem.Allocator;
pub const Cache = Source;

fn Lookup(comptime Key: type) type {
    return union(enum) { hit: terms.Evaluation, miss: Key };
}

fn equalTerms(left_target: u32, left_terms: []const []const u8, right_target: u32, right_terms: []const []const u8) bool {
    const rule = @import("generated_verification_call_equal");

    const input: std.meta.Child(rule.Input) = .{
        .left = &.{ .target = left_target, .terms = left_terms },
        .right = &.{ .target = right_target, .terms = right_terms },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}

const Source = struct {
    pub const Key = struct { target: u32, start: usize, length: usize, digest: u64 };

    const Context = struct {
        leaves: []const []const u8,
        pub fn hash(_: Context, key: Key) u64 {
            return key.digest;
        }
        pub fn eql(self: Context, left: Key, right: Key) bool {
            return equalTerms(left.target, self.leaves[left.start..][0..left.length], right.target, self.leaves[right.start..][0..right.length]);
        }
    };
    const ProbeKey = struct { target: u32, terms: []const []const u8, digest: u64 };

    const ProbeContext = struct {
        leaves: []const []const u8,
        pub fn hash(_: ProbeContext, key: ProbeKey) u64 {
            return key.digest;
        }
        pub fn eql(self: ProbeContext, probe: ProbeKey, stored: Key) bool {
            return equalTerms(probe.target, probe.terms, stored.target, self.leaves[stored.start..][0..stored.length]);
        }
    };
    rows: std.HashMapUnmanaged(Key, terms.Evaluation, Context, std.hash_map.default_max_load_percentage) = .empty,
    leaves: std.ArrayList([]const u8) = .empty,
    pub fn lookup(self: *Source, allocator: Allocator, target: u32, argument: terms.Value) Allocator.Error!Lookup(Key) {
        var frame: Probe = .{ .cache = self, .allocator = allocator };
        const entry = @import("generated_lookup_symbolic_call");

        const input: std.meta.Child(entry.Input) = .{
            .key = @ptrCast(&frame),
            .argument = @ptrCast(&argument),
            .target = target,
        };

        var scratch = std.heap.ArenaAllocator.init(allocator);
        var buffer: [4096]u8 = undefined;
        var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

        defer scratch.deinit();

        entry.executeIn(memory.allocator(), &input) catch |err| switch (err) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
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
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn probeSymbolicCallKey(handle: *anyopaque, target: u32, key_terms: []const []const u8, digest: u64) Allocator.Error!void {
    const probe = Probe.borrow(handle);
    const cache = probe.cache;

    if (cache.rows.getAdapted(
        Source.ProbeKey{ .target = target, .terms = key_terms, .digest = digest },
        Source.ProbeContext{ .leaves = cache.leaves.items },
    )) |value| {
        probe.result = .{ .hit = value };

        return;
    }

    // Offsets survive pool growth while a nested call evaluates this miss.
    const start = cache.leaves.items.len;

    try cache.leaves.appendSlice(probe.allocator, key_terms);

    probe.result = .{ .miss = .{ .target = target, .start = start, .length = key_terms.len, .digest = digest } };
}
