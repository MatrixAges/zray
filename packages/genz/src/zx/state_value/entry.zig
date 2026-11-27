const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const scope = @import("scope.zig");
const conversion = @import("conversion_emission.zig");
const Cache = @import("../expression_map.zig").Map(ir.ExprId);

pub fn enter(self: *Lower) Lower.Error!scope.Frame(.Represented) {
    const cache = if (self.cache.state.count != 0) try represent(self) else Cache.empty;

    return scope.enter(self, .Represented, .{ .cache = cache, .state_active = true });
}

fn represent(self: *Lower) Lower.Error!Cache {
    const entry = @import("generated_convert_represented_cache");
    const Input = std.meta.Child(entry.Input);
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [1024]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&storage, arena.allocator());

    defer arena.deinit();

    const scratch = memory.allocator();
    const map = self.cache.state;

    const source: Input = .{
        .count = map.count,
        .metadata = map.metadata.items,
        .keys = map.keys.items,
        .types = self.program.expressions.types,
        .queries = zx.columns.slice(@FieldType(Input, "queries"), self.state_plan.queries),
    };

    const jobs = entry.executeIn(scratch, &source) catch |err| return failure(err);
    const converted = try scratch.alloc(u32, jobs.slots.len);

    for (jobs.slots, jobs.layouts, converted) |slot, layout, *result| {
        const id: ?ir.TypeId = if (layout) |row| @fromBackingInt(row) else null;

        result.* = @backingInt(try emit(self, id, @fromBackingInt(map.values.items[@intCast(slot)])));
    }

    return publish(self.allocator, source.keys, jobs.slots, converted);
}

fn publish(allocator: std.mem.Allocator, keys: []const u32, slots: []const u64, values: []const u32) Lower.Error!Cache {
    const entry = @import("generated_state_entry_publish");
    const input: std.meta.Child(entry.Input) = .{ .keys = keys, .slots = slots, .values = values };
    const output = entry.executeState(allocator, &input) catch |err| return failure(err);

    return .{ .state = zx.columns.view(@FieldType(Cache, "state"), output) };
}

fn emit(self: *Lower, layout: ?ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const entry = @import("generated_state_entry_emit");
    const EmitCall = std.meta.Child(entry.Input);
    const EmitInput = std.meta.Child(@FieldType(EmitCall, "entry"));
    const Context = std.meta.Child(@FieldType(EmitInput, "context"));
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    var boundary: conversion.Capture = undefined;
    const capture = conversion.captureBoundary(self, &boundary);
    const common = if (layout) |id| try conversion.prepareMode(self, allocator, id, value, .Value, capture) else null;

    const context: Context = .{
        .capture = capture,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: EmitInput = .{ .context = &context, .conversion = if (common) |*prepared| prepared else null, .value = @backingInt(value) };

    const call: EmitCall = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .entry = &input,
    };

    const root = entry.executeIn(allocator, &call) catch |err| return failure(err);

    return @fromBackingInt(root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid state entry conversion"),
    };
}
