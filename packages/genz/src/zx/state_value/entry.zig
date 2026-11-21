const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Scope = @import("root.zig");
const conversion = @import("conversion_emission.zig");
const preparation = @import("generated_state_entry_prepare");
const Input = std.meta.Child(preparation.Input);
const Facts = std.meta.Child(@FieldType(Input, "source"));
const Views = std.meta.Child(@FieldType(Input, "current"));
const Target = std.meta.Child(@FieldType(Input, "target"));
const Cache = @import("../expression_map.zig").Map(ir.ExprId);

pub fn enter(self: *Lower, mode: enum { represented, borrowed }) Lower.Error!Scope {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [1024]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&storage, arena.allocator());

    defer arena.deinit();

    const scratch = memory.allocator();
    const map = &self.cache.state;

    const source: Facts = .{
        .count = map.count,
        .metadata = map.metadata.items,
        .keys = map.keys.items,
        .types = self.program.expressions.types,
        .queries = zx.columns.slice(@FieldType(Facts, "queries"), self.state_plan.queries),
    };

    const current: Views = .{ .types = ids(self.types), .layouts = ids(self.layouts), .active = self.state_active };

    const target: Target = if (mode == .borrowed)
        .{ .types = ids(self.abi_types), .layouts = ids(self.abi_layouts) }

    else
        .{ .types = ids(self.state_types), .layouts = ids(self.state_layouts) };

    const input: Input = .{ .source = &source, .current = &current, .target = &target, .borrowed = mode == .borrowed };
    const plan = preparation.executeIn(scratch, &input) catch |err| return failure(err);
    const previous = plan.previous orelse return .{ .lowering = self, .previous = null };

    const saved: Scope.Saved = .{
        .types = column(previous.types),
        .layouts = column(previous.layouts),
        .cache = if (plan.replace_cache) self.cache else null,
        .active = previous.active,
    };

    const slots = plan.jobs.slots;
    var cache: Cache = .empty;

    if (slots.len != 0) {
        const converted = try scratch.alloc(u32, slots.len);

        for (slots, plan.jobs.layouts, converted) |slot, layout, *value| {
            const id: ?ir.TypeId = if (layout) |type_id| @fromBackingInt(type_id) else null;
            value.* = @backingInt(try emit(self, id, @fromBackingInt(saved.cache.?.state.values.items[slot])));
        }

        cache = try publish(self.allocator, source.keys, slots, converted);
    }

    if (plan.replace_cache) self.cache = cache;

    self.types = column(plan.next.types);
    self.layouts = column(plan.next.layouts);
    self.state_active = plan.next.active;

    return .{ .lowering = self, .previous = saved };
}

fn publish(allocator: std.mem.Allocator, keys: []const u32, slots: []const u64, values: []const u32) Lower.Error!Cache {
    const entry = @import("generated_state_entry_publish");
    const input: std.meta.Child(entry.Input) = .{ .keys = keys, .slots = slots, .values = values };
    const output = entry.executeState(allocator, &input) catch |err| return failure(err);

    return .{ .state = zx.columns.view(@FieldType(Cache, "state"), output) };
}

fn ids(values: []const node.ExpressionId) []const u32 {
    comptime std.debug.assert(@typeInfo(node.ExpressionId).@"enum".tag_type == u32);

    return @as([*]const u32, @ptrCast(values.ptr))[0..values.len];
}

fn column(values: []const u32) []node.ExpressionId {
    return @as([*]node.ExpressionId, @ptrCast(@constCast(values.ptr)))[0..values.len];
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
    var body: std.ArrayList(node.Statement) = .empty;

    return conversion.apply(self, &body, &body, output);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid state entry conversion"),
    };
}
