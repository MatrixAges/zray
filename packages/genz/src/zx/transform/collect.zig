const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const columns = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const elements = @import("../state_value/elements.zig");
const conversion = @import("../state_value/conversion_emission.zig");
const blocks = @import("../../node/blocks.zig");
const Frame = @import("execution.zig").Frame;

pub fn prepareCollectTransform(handle: *const anyopaque, mapping: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.name = if (mapping) "" else try self.fresh("items");

    const element = try elements.typeExpr(self, frame.typeId());

    frame.result = try prepare(self, &frame.body, mapping, frame.source, element, frame.name);
}

pub fn bindMapTransformResult(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.result = try aggregate.bind(self, &frame.body, frame.result);
    frame.index = try self.fresh("index");
}

pub fn storeMapTransformValue(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const value = try aggregate.bind(self, &frame.loop, frame.callback);

    frame.stored = try elements.write(self, &frame.loop, frame.typeId(), value);
}

pub fn storeFilterTransformValue(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const element = @backingInt(frame.transform.parameters[0]);
    const value = try self.builder.identifier(self.names[element]);

    frame.stored = try elements.write(self, &frame.loop, frame.typeId(), value);
    self.used[element] = true;
}

pub fn publishCollectTransform(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    try frame.binding.extend(&frame.loop);

    const outer = try frame.body.block(self.allocator);
    const element_body = try frame.binding.block(self.allocator);

    return @backingInt(try publish(frame, outer, element_body));
}

fn prepare(self: *Lower, body: *blocks.Sequence, mapping: bool, source: node.ExpressionId, element: node.ExpressionId, name: []const u8) Lower.Error!node.ExpressionId {
    const entry = @import("generated_transform_collect_prepare");
    const Input = std.meta.Child(entry.Input);
    var boundary: conversion.Capture = undefined;
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self, &boundary);

    const input: Input = .{
        .bases = &bases,
        .map = mapping,
        .source = @backingInt(source),
        .element = @backingInt(element),
        .name = name,
    };

    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&storage, arena.allocator());

    defer arena.deinit();

    const output = entry.executeIn(scratch.allocator(), &input) catch |err| return failure(err);
    const state = output.state;

    if (!state.valid) return error.OutOfMemory;

    const expressions = columns.join(state.expressions.*, state.forms.*);

    try append(self, &self.builder.nodes.expressions, &expressions);

    const statements = columns.join(state.statements.*, state.variables.*);
    @import("../../node/import_statements.zig").appendBorrowingText(self.allocator, body, &statements) catch |err| return failure(err);

    if (mapping) self.uses_allocator = true;

    return @fromBackingInt(output.id);
}

fn publish(frame: *Frame, body: node.Block, loop: node.Block) Lower.Error!node.ExpressionId {
    const self = frame.lowering;
    const entry = @import("generated_transform_collect_publish");
    const Input = std.meta.Child(entry.Input);
    var boundary: conversion.Capture = undefined;
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self, &boundary);

    const input: Input = .{
        .bases = &bases,
        .source = @backingInt(frame.source),
        .value = @backingInt(frame.stored),
        .result = @backingInt(frame.result),
        .callback = @backingInt(frame.callback),
        .capture = frame.capture,
        .index = frame.index,
        .name = frame.name,
        .element_start = loop.start,
        .element_count = loop.len,
        .outer_count = body.len,
    };

    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&storage, arena.allocator());

    defer arena.deinit();

    const output = entry.executeIn(scratch.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const nodes = self.builder.nodes;
    const expressions = columns.join(output.context.expressions.*, output.context.forms.*);

    try append(self, &nodes.expressions, &expressions);

    try @import("publication.zig").append(self, &.{
        .prelude = output.branch_body,
        .element = loop,
        .step = output.update,
        .outer = body,
        .result = .{ .statements = output.context.statements },
    });

    self.uses_allocator = true;

    const owned = try @import("../state_value/list.zig").owned(self, frame.typeId(), @fromBackingInt(output.result), try self.builder.expression(.{ .boolean = false }));

    return aggregate.finishStored(self, .{ .start = output.outer_start, .len = output.outer_count }, owned, null);
}

fn context(comptime Bases: type, self: *const Lower, boundary: *conversion.Capture) Bases {
    const capture = conversion.captureBoundary(self, boundary);
    const Pointer = @typeInfo(@FieldType(Bases, "capture")).optional.child;

    return .{
        .capture = if (capture) |value| zx.columns.pointer(Pointer, value) else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = 0,
        .serial = self.serial,
    };
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
