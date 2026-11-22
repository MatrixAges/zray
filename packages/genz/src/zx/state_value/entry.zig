const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const scope = @import("scope.zig");
const conversion = @import("conversion_emission.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Cache = @import("../expression_map.zig").Map(ir.ExprId);

pub fn enter(self: *Lower) Lower.Error!scope.Frame(.Represented) {
    const cache = if (self.cache.state.count != 0) try represent(self) else Cache.empty;

    return scope.enter(self, .Represented, .{ .cache = cache, .state_active = true });
}

fn represent(self: *Lower) Lower.Error!Cache {
    const entry = @import("generated_state_entry_schedule");
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
    var frame: Conversion = .{ .lowering = self, .values = map.values.items, .result = converted };
    const execution = @import("generated_convert_represented_cache");

    const input: std.meta.Child(execution.Input) = .{
        .cache = @ptrCast(&frame),
        .slots = jobs.slots,
        .layouts = jobs.layouts,
    };

    try evaluation.execute(execution, &input);

    return publish(self.allocator, source.keys, jobs.slots, converted);
}

const Conversion = struct {
    lowering: *Lower,
    values: []const u32,
    result: []u32,
};

pub fn convertRepresentedCache(handle: *const anyopaque, index: u64, slot: u64, layout: ?u32) Lower.Error!void {
    const frame: *Conversion = @ptrCast(@alignCast(@constCast(handle)));
    const id: ?ir.TypeId = if (layout) |row| @fromBackingInt(row) else null;

    frame.result[@intCast(index)] = @backingInt(try emit(frame.lowering, id, @fromBackingInt(frame.values[@intCast(slot)])));
}

fn publish(allocator: std.mem.Allocator, keys: []const u32, slots: []const u64, values: []const u32) Lower.Error!Cache {
    const entry = @import("generated_state_entry_publish");
    const input: std.meta.Child(entry.Input) = .{ .keys = keys, .slots = slots, .values = values };
    const output = entry.executeState(allocator, &input) catch |err| return failure(err);

    return .{ .state = zx.columns.view(@FieldType(Cache, "state"), output) };
}

fn emit(self: *Lower, layout: ?ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const entry = @import("generated_state_entry_emit");
    const EmitInput = std.meta.Child(entry.Input);
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
    const output = entry.executeIn(allocator, &input) catch |err| return failure(err);

    return conversion.apply(self, null, null, output);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid state entry conversion"),
    };
}
