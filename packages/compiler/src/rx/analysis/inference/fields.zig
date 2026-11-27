const std = @import("std");
const Graph = @import("types.zig");
const Self = @This();
pub const Field = struct { name: []const u8, value: Graph.Id };
pub const Buffers = std.AutoHashMapUnmanaged([*]const Graph.Id, [*]u8);
const Name = []const u8;
const Header = extern struct { capacity: u32, published: u32 };
const row_bytes = @sizeOf(Name) + @sizeOf(Graph.Id);

pub const Layout = struct {
    prefix: u64,
    capacity: u64,
    published: u64,
};

pub const View = struct {
    bytes: [*]const u8 = undefined,
    len: usize = 0,
    pub fn names(self: View) []const []const u8 {
        if (self.len == 0) return &.{};

        const start = self.bytes - @as(usize, self.header().capacity) * @sizeOf(Name);

        return @as([*]const Name, @ptrCast(@alignCast(start)))[0..self.len];
    }

    pub fn values(self: View) []const Graph.Id {
        if (self.len == 0) return &.{};

        return @as([*]const Graph.Id, @ptrCast(@alignCast(self.bytes + @sizeOf(Header))))[0..self.len];
    }

    pub fn copyTo(self: View, destination: Self) void {
        @memcpy(destination.nameColumn()[0..self.len], self.names());
        @memcpy(destination.valueColumn()[0..self.len], self.values());
    }

    pub fn at(self: View, index: usize) Field {
        return .{ .name = self.names()[index], .value = self.values()[index] };
    }

    fn header(self: View) *const Header {
        return @ptrCast(@alignCast(self.bytes));
    }
};

bytes: [*]u8 = undefined,
len: usize = 0,
pub fn init(buffers: *Buffers, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    const fields = try allocate(buffers, allocator, count, count);

    if (count != 0) fields.header().published = @intCast(count);

    return fields;
}

pub fn layout(fields: Self) Layout {
    const header_value = if (fields.len == 0) Header{ .capacity = 0, .published = 0 } else fields.header().*;

    return .{
        .prefix = fields.len,
        .capacity = header_value.capacity,
        .published = header_value.published,
    };
}

pub fn grow(buffers: *Buffers, allocator: std.mem.Allocator, existing: Self, count: usize, capacity: ?usize) std.mem.Allocator.Error!Self {
    if (capacity) |size| {
        const next = try allocate(buffers, allocator, count, size);

        if (existing.len != 0) existing.copyTo(next);
        if (count != 0) next.header().published = @intCast(count);

        return next;
    }

    var resized = existing;

    resized.len = count;

    if (count != 0) resized.header().published = @intCast(count);

    return resized;
}

fn allocate(buffers: *Buffers, allocator: std.mem.Allocator, count: usize, capacity: usize) std.mem.Allocator.Error!Self {
    if (capacity == 0) return .{};

    const reserved = std.math.cast(u32, capacity) orelse return error.OutOfMemory;
    const rows = std.math.mul(usize, capacity, row_bytes) catch return error.OutOfMemory;
    const size = std.math.add(usize, rows, @sizeOf(Header)) catch return error.OutOfMemory;
    const storage = try allocator.alignedAlloc(u8, .of(Name), size);
    const fields: Self = .{ .bytes = storage.ptr + capacity * @sizeOf(Name), .len = count };

    fields.header().capacity = reserved;

    try buffers.put(allocator, fields.valuePtr(), fields.bytes);

    return fields;
}

/// Reconstruct a read-only descriptor from the complete value column of this layout.
pub fn viewFromValues(column: []const Graph.Id) View {
    if (column.len == 0) return .{};

    const data: [*]const u8 = @ptrCast(column.ptr);

    return .{ .bytes = data - @sizeOf(Header), .len = column.len };
}

pub fn fromValues(buffers: *const Buffers, column: []const Graph.Id) Self {
    if (column.len == 0) return .{};

    return .{ .bytes = buffers.get(column.ptr).?, .len = column.len };
}

pub fn view(self: Self) View {
    return .{ .bytes = self.bytes, .len = self.len };
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

    return self.valuePtr()[0..self.len];
}

fn valuePtr(self: Self) [*]Graph.Id {
    return @ptrCast(@alignCast(self.bytes + @sizeOf(Header)));
}

fn header(self: Self) *Header {
    return @ptrCast(@alignCast(self.bytes));
}
