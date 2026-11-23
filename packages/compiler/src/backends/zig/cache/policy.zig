const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
pub const Route = enum { Held, Stored, Missing };
pub const Previous = struct { pending: usize, source: []const u8 };
pub const Replacement = struct { append: ?usize, retire: ?usize };
pub const Mode = enum { Wait, Synchronous, Background };
pub const Action = enum { Idle, Join, Drain, Spawn };
pub const Schedule = struct { finish: Action, start: Action };
pub const CacheAction = enum { Reuse, Open, Replace };
pub const Resident = struct { action: CacheAction, record_trace: bool };

pub fn lookup(resident_key: ?*const [32]u8, key: *const [32]u8, storage: bool) Route {
    if (comptime !generated) {
        if (resident_key) |old| if (std.mem.eql(u8, old, key)) return .Held;

        return if (storage) .Stored else .Missing;
    }

    const rule = @import("generated_generation_cache_lookup");
    const input: valueType(rule.Input) = .{ .resident = if (resident_key) |old| old else null, .key = key, .storage = storage };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return @fromBackingInt(@intCast(@backingInt(result)));
}

pub fn replaceSeed(previous: ?Previous, queue: anytype, persistent: bool, needs_write: bool) Replacement {
    return .{
        .append = if (persistent and needs_write) queue.len else null,
        .retire = if (previous) |old| blk: {
            if (old.pending >= queue.len) break :blk null;

            const item = queue[old.pending].source;

            break :blk if (item.ptr == old.source.ptr and item.len == old.source.len) old.pending else null;
        } else null,
    };
}

pub fn schedule(mode: Mode, active: bool, threaded: bool, waiting: bool) Schedule {
    return .{
        .finish = if (threaded) .Join else if (active) .Drain else .Idle,
        .start = if (waiting) switch (mode) {
            .Wait => .Idle,
            .Synchronous => .Drain,
            .Background => .Spawn,
        } else .Idle,
    };
}

pub fn resident(existing: ?[]const u8, path: []const u8, keep_trace: bool) Resident {
    if (comptime !generated) {
        const action: CacheAction = if (existing) |old| if (std.mem.eql(u8, old, path)) .Reuse else .Replace else .Open;

        return .{ .action = action, .record_trace = keep_trace };
    }

    const rule = @import("generated_generation_cache_resident");
    const input: valueType(rule.Input) = .{ .existing = existing, .path = path, .resident = keep_trace };
    var buffer: [128]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{ .action = @fromBackingInt(@intCast(@backingInt(result.action))), .record_trace = result.record_trace };
}

fn valueType(comptime Input: type) type {
    return if (@typeInfo(Input) == .pointer) std.meta.Child(Input) else Input;
}
