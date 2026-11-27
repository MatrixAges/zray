const std = @import("std");
const Lower = @import("../lower.zig");
const Id = @import("../../node.zig").ExpressionId;

fn run(comptime entry: type, scratch: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]const u32 {
    const Parameter = entry.Input;
    const Input = if (comptime @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const input: Input = .{ .count = count };

    return entry.executeIn(scratch, if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch |err| failure(err);
}

pub fn allocateAbi(allocator: std.mem.Allocator, count: usize, types: *[]Id, layouts: *[]Id) std.mem.Allocator.Error!void {
    const entry = @import("generated_lowering_workspace_abi");
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var scratch_bytes: [1024]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_bytes, arena.allocator());
    const zeros = try run(entry, fallback.allocator(), count);
    const values = try allocator.alloc(Id, count);
    const slots = try allocator.alloc(Id, count);

    @memcpy(values, @as([]const Id, @ptrCast(zeros)));
    @memcpy(slots, @as([]const Id, @ptrCast(zeros)));

    types.* = values;
    layouts.* = slots;
}

pub fn prepareShared(self: *Lower) std.mem.Allocator.Error!void {
    const entry = @import("generated_lowering_workspace_shared");
    const count = self.types.len;
    var arena = std.heap.ArenaAllocator.init(self.allocator);

    defer arena.deinit();

    var scratch_bytes: [1024]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_bytes, arena.allocator());
    const sentinels = try run(entry, fallback.allocator(), count);
    const values: []const Id = @ptrCast(sentinels);
    self.state_types = try self.allocator.alloc(Id, count);
    self.state_layouts = try self.allocator.alloc(Id, count);
    self.view_types = try self.allocator.alloc(Id, count);

    @memcpy(self.abi_types, values);
    @memcpy(self.abi_layouts, values);
    @memcpy(self.state_types, values);
    @memcpy(self.state_layouts, values);
    @memcpy(self.view_types, values);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
