const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const publication = @import("generated_type_resolution_publication");
const lookup = @import("generated_resolved_name_lookup");
const Input = std.meta.Child(publication.Input);
pub const Cache = std.meta.Child(@FieldType(Input, "cache"));
const Self = @This();

const Columns = struct {
    names: std.ArrayList([]const u8) = .empty,
    ids: std.ArrayList(u32) = .empty,
};

columns: Columns = .{},
buckets: []u32 = &.{},
pub fn count(self: *const Self) u32 {
    return @intCast(self.columns.names.items.len);
}

pub fn view(self: *const Self, comptime Layout: type) Layout {
    return .{ .names = self.columns.names.items, .ids = self.columns.ids.items };
}

fn position(self: *const Self, name: []const u8) ?usize {
    const keys = memory.borrowTextSlice(self.columns.names.items);
    const InputView = std.meta.Child(lookup.Input);

    const input: InputView = .{
        .names = self.columns.names.items,
        .keys = @ptrCast(&keys),
        .buckets = self.buckets,
        .name = name,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const row = lookup.executeIn(scratch.allocator(), &input) catch unreachable;

    return @intCast(row orelse return null);
}

pub fn get(self: *const Self, name: []const u8) ?zx.ir.TypeId {
    return @fromBackingInt(self.columns.ids.items[self.position(name) orelse return null]);
}

pub fn put(self: *Self, allocator: std.mem.Allocator, name: []const u8, id: zx.ir.TypeId) std.mem.Allocator.Error!void {
    if (self.position(name)) |row| {
        self.columns.ids.items[row] = @backingInt(id);

        return;
    }

    try self.publish(allocator, &.{ .names = &.{name}, .ids = &.{@backingInt(id)} });
}

pub fn publish(self: *Self, allocator: std.mem.Allocator, cache: *const Cache) std.mem.Allocator.Error!void {
    const first = self.columns.names.items.len;

    if (cache.names.len != 0) {
        const required = std.math.add(usize, first, cache.names.len) catch return error.OutOfMemory;

        if (required > std.math.maxInt(u32)) return error.OutOfMemory;
        try self.columns.names.ensureTotalCapacity(allocator, required);
        try self.columns.ids.ensureTotalCapacity(allocator, required);

        self.columns.names.appendSliceAssumeCapacity(cache.names);
        self.columns.ids.appendSliceAssumeCapacity(cache.ids);
    }

    errdefer if (cache.names.len != 0) {
        self.columns.names.shrinkRetainingCapacity(first);
        self.columns.ids.shrinkRetainingCapacity(first);
    };

    const keys = memory.borrowTextSlice(self.columns.names.items);

    const input: Input = .{
        .cache = cache,
        .keys = @ptrCast(&keys),
        .buckets = self.buckets,
        .first = first,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const updated = (publication.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    }) orelse return;

    if (updated.rebuilt) |next| {
        const owned = try allocator.dupe(u32, next);

        allocator.free(self.buckets);

        self.buckets = owned;
    }

    if (updated.changes) |changes| {
        for (changes.slots, changes.entries) |slot, entry| {
            self.buckets[@intCast(slot)] = entry;
        }
    }
}
