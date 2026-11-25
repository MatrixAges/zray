const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("genz_options").generated_analysis;
const adding = @import("generated_members_add");
const State = if (generated) @typeInfo(@typeInfo(@TypeOf(adding.executeState)).@"fn".return_type.?).error_union.payload else std.AutoHashMapUnmanaged(ir.SymbolId, void);
const Self = @This();

state: State = if (generated) .{
    .count = 0,
    .keys = .{ .items = &.{}, .storage = .plain },
    .buckets = .{ .items = &.{}, .storage = .plain },
} else .empty,

borrowed: ?*State = null,
pub const empty: Self = .{};
pub const Checkpoint = if (generated) u64 else []const ir.SymbolId;

pub fn checkpoint(self: *Self) Checkpoint {
    return self.current().count;
}

pub fn restore(self: *Self, before: Checkpoint) void {
    if (!generated) return self.removeMany(before);

    const state = self.current();

    std.debug.assert(before <= state.count);

    if (state.count == before) return;

    const entry = @import("generated_members_trim");
    const Input = std.meta.Child(entry.Input);
    const index = writable(std.meta.Child(@FieldType(Input, "index")), state);
    const input: Input = .{ .index = &index, .first = before };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

    state.count = before;
}

pub fn inherit(self: *Self) Self {
    if (!generated) return self.*;

    return .{ .borrowed = self.current() };
}

pub fn put(self: *Self, allocator: std.mem.Allocator, key: ir.SymbolId, value: void) std.mem.Allocator.Error!void {
    if (!generated) return self.state.put(allocator, key, value);

    const state = self.current();

    state.* = adding.executeState(allocator, .{ .index = state.*, .key = @backingInt(key) }) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn remove(self: *Self, key: ir.SymbolId) bool {
    if (!generated) return self.state.remove(key);

    const state = self.current();
    const entry = @import("generated_members_remove");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .count = state.count,
        .keys = @ptrCast(&state.keys.items),
        .buckets = @ptrCast(&state.buckets.items),
        .key = @backingInt(key),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const position = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;

    state.count -= @intFromBool(position != null);

    return position != null;
}

/// Reserve the complete batch before writing live keys and buckets.
pub fn addMany(self: *Self, allocator: std.mem.Allocator, keys: []const ir.SymbolId) std.mem.Allocator.Error!void {
    if (!generated) {
        var added: usize = 0;

        errdefer self.removeMany(keys[0..added]);

        for (keys) |key| {
            try self.put(allocator, key, {});

            added += 1;
        }

        return;
    }

    if (keys.len == 0) return;

    const entry = @import("generated_members_add_many");
    const Parameter = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const state = self.current();
    var key_buffer: []u32 = undefined;
    var bucket_buffer: []u32 = undefined;

    const input: Input = .{
        .index = zx.columns.view(@FieldType(Input, "index"), state.*),
        .keys = .{ .items = @import("../node/view.zig").slice([]const u32, keys), .storage = .plain },
        .key_buffer = @ptrCast(&key_buffer),
        .bucket_buffer = @ptrCast(&bucket_buffer),
    };

    const next = entry.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| {
        self.restoreBuckets();

        return switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
            else => unreachable,
        };
    };

    state.* = zx.columns.view(State, next);
}

pub fn removeMany(self: *Self, keys: []const ir.SymbolId) void {
    for (keys) |key| _ = self.remove(key);
}

pub fn restoreBuckets(self: *Self) void {
    const entry = @import("generated_members_restore");
    const input = writable(std.meta.Child(entry.Input), self.current());
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;
}

fn writable(comptime Target: type, state: *State) Target {
    return .{
        .count = state.count,
        .keys = @ptrCast(&state.keys.items),
        .buckets = @ptrCast(&state.buckets.items),
    };
}

pub fn contains(self: *const Self, key: ir.SymbolId) bool {
    if (!generated) return self.state.contains(key);

    const querying = @import("generated_members_get");
    const Input = std.meta.Child(querying.Input);
    const index = self.view(std.meta.Child(@FieldType(Input, "index")));
    const input: Input = .{ .index = &index, .key = @backingInt(key) };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(querying.executeValue, fixed.allocator(), &input) catch unreachable;

    return result != null;
}

pub fn view(self: *const Self, comptime Target: type) Target {
    const state = if (self.borrowed) |value| value else &self.state;

    return .{ .count = state.count, .keys = state.keys.items, .buckets = state.buckets.items };
}

pub fn current(self: *Self) *State {
    return self.borrowed orelse &self.state;
}
