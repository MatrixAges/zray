const std = @import("std");
const zx = @import("zx");
const ir = @import("../ir.zig");
const capacity = @import("generated_byte_map_capacity");
const lookup = @import("generated_byte_map_lookup");
const rehash = @import("generated_byte_map_rehash");
const Rows = std.MultiArrayList(struct { key: ?[]const u8, value: u32 });
const Terms = @import("../terms.zig");
const Error = Terms.Error;
const Self = @This();
pub const empty: Self = .{};

rows: Rows = .empty,
count: u32 = 0,
limit: usize = 0,
pub const View = struct {
    keys: []?[]const u8,
    values: []u32,
};

pub fn view(self: *const Self) View {
    const slice = self.rows.slice();

    return .{ .keys = slice.items(.key), .values = slice.items(.value) };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.rows.deinit(allocator);
}

pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, count: u32) std.mem.Allocator.Error!void {
    if (count <= self.limit) return;

    const size = try capacity.executeValue(allocator, count);
    const length = std.math.cast(usize, size.capacity) orelse return error.OutOfMemory;
    var next: Self = .{ .rows = try Rows.initCapacity(allocator, length), .limit = @intCast(size.limit) };

    errdefer next.deinit(allocator);

    next.rows.len = length;

    const dest = next.view();

    if (self.count > 0) {
        const source = self.view();
        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        const input: std.meta.Child(rehash.Input) = .{
            .capacity = length,
            .keys = source.keys,
            .values = source.values,
        };

        const rebuilt = zx.columns.invoke(rehash.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        @memcpy(dest.keys, rebuilt.keys);
        @memcpy(dest.values, rebuilt.values);

        next.count = rebuilt.count;
    } else {
        @memset(dest.keys, null);
    }

    self.deinit(allocator);

    self.* = next;
}

const Match = @typeInfo(@typeInfo(@TypeOf(lookup.executeValue)).@"fn".return_type.?).error_union.payload;

pub fn find(self: *const Self, allocator: std.mem.Allocator, key: []const u8) Error!Match {
    const cols = self.view();
    const input: std.meta.Child(lookup.Input) = .{ .keys = cols.keys, .values = cols.values, .key = key, .full = self.count == self.limit };

    return zx.columns.invoke(lookup.executeValue, allocator, &input) catch |err| Terms.fromSourceError(err);
}

pub fn fillVacant(self: *Self, position: usize, key: []const u8, id: ir.Id) void {
    self.rows.set(position, .{ .key = key, .value = @backingInt(id) });

    self.count += 1;
}
