const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../node.zig");
const generated = @import("genz_options").generated_analysis;
const writing = @import("generated_transfer_append");
const State = if (generated) @typeInfo(@typeInfo(@TypeOf(writing.executeState)).@"fn".return_type.?).error_union.payload else std.ArrayList(Record);
const Self = @This();
pub const Record = struct { type_id: ir.TypeId, owner: node.ExpressionId, value: node.ExpressionId, ready: node.ExpressionId };

state: State = if (generated) .{
    .types = .{ .items = &.{}, .storage = .plain },
    .owners = .{ .items = &.{}, .storage = .plain },
    .values = .{ .items = &.{}, .storage = .plain },
    .ready = .{ .items = &.{}, .storage = .plain },
} else .empty,

pub const empty: Self = .{};

pub fn append(self: *Self, allocator: std.mem.Allocator, record: Record) std.mem.Allocator.Error!void {
    return self.state.append(allocator, record);
}

pub fn retain(self: *Self, allocator: std.mem.Allocator, type_id: u32, owner: u32, value: u32, ready: u32) std.mem.Allocator.Error!void {
    const Input = @typeInfo(@TypeOf(writing.executeState)).@"fn".param_types[1].?;
    const Target = std.meta.Child(@FieldType(Input, "record"));

    const record: Target = .{
        .type_id = type_id,
        .owner = owner,
        .value = value,
        .ready = ready,
    };

    self.state = writing.executeState(allocator, .{
        .state = self.state,
        .record = &record,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn view(self: *const Self, comptime Target: type) Target {
    return .{ .types = self.state.types.items, .owners = self.state.owners.items, .values = self.state.values.items, .ready = self.state.ready.items };
}

pub fn len(self: *const Self) usize {
    return if (generated) self.state.types.items.len else self.state.items.len;
}

pub fn at(self: *const Self, index: usize) Record {
    return self.state.items[index];
}

pub fn iterator(self: *const Self) Iterator {
    return .{ .owner = self };
}

pub const Iterator = struct {
    owner: *const Self,
    index: usize = 0,
    pub fn next(self: *@This()) ?Record {
        if (self.index == self.owner.len()) return null;

        const value = self.owner.at(self.index);

        self.index += 1;

        return value;
    }
};
