const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const publication = @import("generated_type_resolution_publication");
const lookup = @import("generated_resolved_name_lookup");
const Input = std.meta.Child(publication.Input);
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Index = std.meta.Child(@FieldType(Destination, "index"));
pub const Cache = std.meta.Child(@FieldType(Input, "cache"));
pub const TypePublication = std.meta.Child(@typeInfo(@FieldType(Input, "types")).optional.child);
const Self = @This();

const Columns = struct {
    names: std.ArrayList([]const u8) = .empty,
    ids: std.ArrayList(u32) = .empty,
};

columns: Columns = .{},
buckets: memory.U32Scratch = .{ .allocator = undefined },
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
        .index = &.{ .keys = @ptrCast(&keys), .buckets = @ptrCast(&self.buckets.items) },
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

    try self.publish(allocator, &.{ .names = &.{name}, .ids = &.{@backingInt(id)} }, null);
}

pub fn publish(self: *Self, allocator: std.mem.Allocator, cache: *const Cache, types: ?*const TypePublication) std.mem.Allocator.Error!void {
    self.buckets.allocator = allocator;

    var keys = memory.borrowTextSlice(self.columns.names.items);
    var tails: Cache = .{ .names = &.{}, .ids = &.{} };
    const slots = memory.bindColumnRanges(&self.columns, cache.*, &tails);
    const ranges: memory.ColumnRanges = &slots;
    const index: Index = .{ .keys = @ptrCast(&keys), .buckets = @ptrCast(&self.buckets.items) };

    const target: Destination = .{
        .committed = @ptrCast(&self.columns.names.items),
        .names = @ptrCast(&tails.names),
        .ids = @ptrCast(&tails.ids),
        .ranges = @ptrCast(&ranges),
        .index = &index,
        .scratch = @ptrCast(&self.buckets),
        .resource = @ptrCast(&allocator),
        .first = self.columns.names.items.len,
    };

    const input: Input = .{ .cache = cache, .destination = &target, .types = types };

    publication.executeIn(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}
