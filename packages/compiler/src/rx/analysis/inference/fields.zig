const std = @import("std");
const Graph = @import("types.zig");
const Self = @This();
pub const Field = struct { name: []const u8, value: Graph.Id };
const Name = []const u8;
const Header = extern struct { capacity: u32, published: u32 };
const row_bytes = @sizeOf(Name) + @sizeOf(Graph.Id);

bytes: [*]u8 = undefined,
len: usize = 0,
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    return allocate(allocator, count, count);
}

fn allocate(allocator: std.mem.Allocator, count: usize, capacity: usize) std.mem.Allocator.Error!Self {
    if (capacity == 0) return .{};

    const reserved = std.math.cast(u32, capacity) orelse return error.OutOfMemory;
    const rows = std.math.mul(usize, capacity, row_bytes) catch return error.OutOfMemory;
    const size = std.math.add(usize, rows, @sizeOf(Header)) catch return error.OutOfMemory;
    const storage = try allocator.alignedAlloc(u8, .of(Name), size);
    const fields: Self = .{ .bytes = storage.ptr + capacity * @sizeOf(Name), .len = count };

    fields.header().* = .{ .capacity = reserved, .published = @intCast(count) };

    return fields;
}

/// Extending the most recently published prefix cannot modify any earlier view.
pub fn extend(self: Self, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    std.debug.assert(count >= self.len);

    if (count == self.len) return self;

    if (self.len != 0) {
        const layout = self.header();

        if (layout.published == self.len and count <= layout.capacity) {
            layout.published = @intCast(count);

            return .{ .bytes = self.bytes, .len = count };
        }
    }

    const reserve = self.len + self.len / 2;
    const capacity = @max(count, @min(reserve, std.math.maxInt(u32)));
    const destination = try allocate(allocator, count, capacity);

    self.copyTo(destination);

    return destination;
}

/// Reconstruct the descriptor from the complete value column of this layout.
pub fn fromValues(column: []const Graph.Id) Self {
    if (column.len == 0) return .{};

    const data: [*]const u8 = @ptrCast(column.ptr);

    return .{ .bytes = @constCast(data - @sizeOf(Header)), .len = column.len };
}

pub fn names(self: Self) []const []const u8 {
    return self.nameColumn();
}

pub fn values(self: Self) []const Graph.Id {
    return self.valueColumn();
}

pub fn set(self: Self, index: usize, name: []const u8, value: Graph.Id) void {
    self.nameColumn()[index] = name;
    self.valueColumn()[index] = value;
}

pub fn copyTo(self: Self, destination: Self) void {
    @memcpy(destination.nameColumn()[0..self.len], self.names());
    @memcpy(destination.valueColumn()[0..self.len], self.values());
}

pub fn nameColumn(self: Self) []Name {
    if (self.len == 0) return &.{};

    const start = self.bytes - @as(usize, self.header().capacity) * @sizeOf(Name);

    return @as([*]Name, @ptrCast(@alignCast(start)))[0..self.len];
}

pub fn valueColumn(self: Self) []Graph.Id {
    if (self.len == 0) return &.{};

    return @as([*]Graph.Id, @ptrCast(@alignCast(self.bytes + @sizeOf(Header))))[0..self.len];
}

fn header(self: Self) *Header {
    return @ptrCast(@alignCast(self.bytes));
}
