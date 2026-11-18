const std = @import("std");
const ir = @import("zx").ir;
const Self = @This();
pub const Kind = enum { Call, Parallel, Return, Task, Selection };
pub const Publish = enum { None, Evaluate, Constant };

pub const Step = struct {
    kind: Kind,
    output: Publish = .None,
    first: u32 = 0,
    count: u32 = 0,
    exhaustive: bool = false,
    value: ?*const ir.Program = null,
    name: ?[]const u8 = null,
};

pub const Case = struct { body: u32, value: ?*const ir.Program };
pub const Call = struct { getters: u32, publishes: bool };
const Unit = struct { first: u32, count: u32, block: bool };

steps: std.MultiArrayList(Step) = .{},
units: std.MultiArrayList(Unit) = .{},
cases: std.MultiArrayList(Case) = .{},
calls: std.MultiArrayList(Call) = .{},
block_count: u32 = 0,
pub fn reserveSteps(self: *Self, allocator: std.mem.Allocator, count: u32) std.mem.Allocator.Error!u32 {
    const first = try index(self.steps.len);
    const end = std.math.add(u32, first, count) catch return error.OutOfMemory;

    try self.steps.resize(allocator, end);

    return first;
}

pub fn reserveCases(self: *Self, allocator: std.mem.Allocator, count: u32) std.mem.Allocator.Error!u32 {
    const first = try index(self.cases.len);
    const end = std.math.add(u32, first, count) catch return error.OutOfMemory;

    try self.cases.resize(allocator, end);

    return first;
}

/// Child units are published before their enclosing unit so layout can read their summaries in one pass.
pub fn unit(self: *Self, allocator: std.mem.Allocator, first: u32, count: u32, block: bool) std.mem.Allocator.Error!u32 {
    const id = try index(self.units.len);

    if (id == std.math.maxInt(u32)) return error.OutOfMemory;
    try self.units.append(allocator, .{ .first = first, .count = count, .block = block });

    self.block_count += @intFromBool(block);

    return id;
}

pub fn index(value: usize) std.mem.Allocator.Error!u32 {
    return std.math.cast(u32, value) orelse error.OutOfMemory;
}
