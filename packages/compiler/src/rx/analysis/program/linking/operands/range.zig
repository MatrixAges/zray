const Storage = @import("zx").ir.ExpressionStorage;
const Self = @This();

firsts: []u32,
counts: []u32,
first: u32,
pub fn init(storage: *Storage, comptime name: []const u8, first: usize) Self {
    return .{
        .firsts = @field(storage, name ++ "_first").unusedCapacitySlice()[0..1],
        .counts = @field(storage, name ++ "_count").unusedCapacitySlice()[0..1],
        .first = @intCast(first),
    };
}

pub fn view(self: *const Self, comptime Target: type) Target {
    return .{ .firsts = @ptrCast(&self.firsts), .counts = @ptrCast(&self.counts), .first = self.first };
}
