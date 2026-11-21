const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const columns = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const elements = @import("../state_value/elements.zig");
const conversion = @import("../state_value/conversion_emission.zig");
const Statements = std.ArrayList(node.Statement);

pub const Request = struct {
    transform: ir.Transform,
    source: node.ExpressionId,
    type_id: ir.TypeId,
    callback: node.ExpressionId,
};

pub fn lower(self: *Lower, body: *Statements, request: Request) Lower.Error!node.ExpressionId {
    const transform = request.transform;
    const mapping = transform.kind == .map;
    const element = transform.parameters[0];
    const capture = self.names[@backingInt(element)];
    const source_type = self.program.expression(transform.target).type_id;

    try @import("context.zig").bind(self, body, transform);

    const name = if (mapping) "" else try self.fresh("items");
    const element_type = try elements.typeExpr(self, request.type_id);
    const allocation = try prepare(self, body, mapping, request.source, element_type, name);
    const result = if (mapping) try aggregate.bind(self, body, allocation) else allocation;
    const index_capture = if (mapping) try self.fresh("index") else null;
    var loop: Statements = .empty;
    const value = if (mapping) try aggregate.bind(self, &loop, request.callback) else try self.builder.identifier(capture);
    const stored = try elements.write(self, &loop, request.type_id, value);

    if (!mapping) self.used[@backingInt(element)] = true;

    const captured = try elements.captureName(self, &loop, source_type, element);

    return publish(self, body.items, loop.items, .{
        .source = request.source,
        .value = stored,
        .result = result,
        .callback = request.callback,
        .capture = captured,
        .index = index_capture,
        .name = name,
        .type_id = request.type_id,
    });
}

fn prepare(self: *Lower, body: *Statements, mapping: bool, source: node.ExpressionId, element: node.ExpressionId, name: []const u8) Lower.Error!node.ExpressionId {
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

const Result = struct {
    source: node.ExpressionId,
    value: node.ExpressionId,
    result: node.ExpressionId,
    callback: node.ExpressionId,
    capture: []const u8,
    index: ?[]const u8,
    name: []const u8,
    type_id: ir.TypeId,
};

fn publish(self: *Lower, body: []const node.Statement, loop: []const node.Statement, result: Result) Lower.Error!node.ExpressionId {
    const entry = @import("generated_transform_collect_publish");
    const Input = std.meta.Child(entry.Input);
    var boundary: conversion.Capture = undefined;
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self, &boundary);

    const input: Input = .{
        .bases = &bases,
        .source = @backingInt(result.source),
        .value = @backingInt(result.value),
        .result = @backingInt(result.result),
        .callback = @backingInt(result.callback),
        .capture = result.capture,
        .index = result.index,
        .name = result.name,
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
    try append(self, &nodes.statements, output.branch_body);

    _ = try self.builder.statements(loop);

    try append(self, &nodes.statements, output.update);

    _ = try self.builder.statements(body);

    try append(self, &nodes.statements, output.context.statements);

    self.uses_allocator = true;
    const owned = try @import("../state_value/list.zig").owned(self, result.type_id, @fromBackingInt(output.result), try self.builder.expression(.{ .boolean = false }));

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
