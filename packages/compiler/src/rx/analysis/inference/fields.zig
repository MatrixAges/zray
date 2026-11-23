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
    const fields = try allocate(allocator, count, count);

    if (count != 0) fields.header().published = @intCast(count);

    return fields;
}

fn allocate(allocator: std.mem.Allocator, count: usize, capacity: usize) std.mem.Allocator.Error!Self {
    if (capacity == 0) return .{};

    const reserved = std.math.cast(u32, capacity) orelse return error.OutOfMemory;
    const rows = std.math.mul(usize, capacity, row_bytes) catch return error.OutOfMemory;
    const size = std.math.add(usize, rows, @sizeOf(Header)) catch return error.OutOfMemory;
    const storage = try allocator.alignedAlloc(u8, .of(Name), size);
    const fields: Self = .{ .bytes = storage.ptr + capacity * @sizeOf(Name), .len = count };

    fields.header().capacity = reserved;

    return fields;
}

pub const Resize = struct {
    allocator: std.mem.Allocator,
    fields: Self,
    names: []Name = undefined,
    values: []u32 = undefined,
    extent: []u32 = undefined,
    pub fn borrow(self: *Resize, comptime View: type) View {
        const fields = self.fields;
        const layout = if (fields.len == 0) Header{ .capacity = 0, .published = 0 } else fields.header().*;

        return .{
            .frame = @ptrCast(self),
            .source_names = fields.names(),
            .source_values = @ptrCast(fields.values()),
            .capacity = layout.capacity,
            .published = layout.published,
            .target_names = @ptrCast(&self.names),
            .target_values = @ptrCast(&self.values),
            .extent = @ptrCast(&self.extent),
        };
    }
};

pub fn bindFieldColumns(handle: *const anyopaque, count: u64, capacity: ?u64) std.mem.Allocator.Error!void {
    const frame: *Resize = @ptrCast(@alignCast(@constCast(handle)));
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;

    if (capacity) |size| {
        const reserved = std.math.cast(usize, size) orelse return error.OutOfMemory;

        frame.fields = try allocate(frame.allocator, length, reserved);
    } else {
        frame.fields.len = length;
    }

    frame.names = frame.fields.nameColumn();
    frame.values = @ptrCast(frame.fields.valueColumn());
    frame.extent = (&frame.fields.header().published)[0..1];
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
