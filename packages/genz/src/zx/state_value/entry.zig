const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const conversion = @import("conversion_emission.zig");
const advancing = @import("generated_state_entry_advance");
const Parameter = @typeInfo(@TypeOf(advancing.executeState)).@"fn".param_types[1].?;
const Input = Child(Parameter);
const Walk = @FieldType(Input, "state");
const Cache = @import("../expression_map.zig").Map(ir.ExprId);

pub fn lower(self: *Lower, previous: *const Cache) Lower.Error!Cache {
    const Facts = std.meta.Child(@FieldType(Input, "source"));

    const source: Facts = .{
        .count = previous.state.count,
        .metadata = previous.state.metadata.items,
        .keys = previous.state.keys.items,
        .values = previous.state.values.items,
        .types = self.program.expressions.types,
        .queries = zx.columns.slice(@FieldType(Facts, "queries"), self.state_plan.queries),
    };

    const empty: Cache = .empty;

    var state: Walk = .{
        .cache = zx.columns.view(@FieldType(Walk, "cache"), empty.state),
        .cursor = 0,
        .work = null,
    };

    var converted: ?u32 = null;

    while (true) {
        const input: Input = .{ .source = &source, .state = state, .converted = converted };

        state = advancing.executeState(self.allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);
        const work = state.work orelse break;
        const layout: ?ir.TypeId = if (work.layout) |id| @fromBackingInt(id) else null;
        converted = @backingInt(try emit(self, layout, @fromBackingInt(work.value)));
    }

    return .{ .state = zx.columns.view(@TypeOf(empty.state), state.cache) };
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

fn Child(comptime Value: type) type {
    return if (@typeInfo(Value) == .pointer) std.meta.Child(Value) else Value;
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid state entry conversion"),
    };
}
