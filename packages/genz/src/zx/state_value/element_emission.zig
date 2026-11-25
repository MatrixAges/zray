const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const conversion = @import("conversion_emission.zig");
const querying = @import("generated_state_element_query");
const Query = std.meta.Child(querying.Input);
const Facts = std.meta.Child(@FieldType(Query, "source"));
const Operation = @FieldType(Query, "operation");
const Sequence = @import("../../node/blocks.zig").Sequence;
const lists = @import("list_emission.zig");
const context = @import("../construction/context.zig");
const runner = @import("generated_run_state_element");
const capturing = @import("generated_run_state_element_capture");
const emitter = @import("generated_state_element_emit");
const Input = std.meta.Child(emitter.Input);
const Decision = @typeInfo(@typeInfo(@TypeOf(querying.executeValue)).@"fn".return_type.?).error_union.payload;

pub fn inlineStored(self: *const Lower, list: ir.TypeId) bool {
    const entry = @import("generated_state_inline_stored");
    const Inline = std.meta.Child(entry.Input);
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Inline, "types")), self.program.types);
    const input: Inline = .{ .types = &types, .selected = self.state_plan.selected, .element_storage = self.state_plan.element_storage, .list = @backingInt(list) };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch @panic("invalid inline element query");
}

pub fn typeExpr(self: *Lower, list: ir.TypeId) Lower.Error!node.ExpressionId {
    const decision = choice(self, list, .Type, false);

    return @import("../types.zig").resource(self, @fromBackingInt(decision.type_id), decision.table);
}

pub fn read(self: *Lower, body: *Sequence, list: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return @fromBackingInt(try run(runner, self, body, list, .Read, @backingInt(value), null));
}

pub fn write(self: *Lower, body: *Sequence, list: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return @fromBackingInt(try run(runner, self, body, list, .Write, @backingInt(value), null));
}

pub fn captureName(self: *Lower, body: *Sequence, list: ir.TypeId, symbol: ir.SymbolId) Lower.Error![]const u8 {
    return run(capturing, self, body, list, .Capture, 0, symbol);
}

pub fn choice(self: *const Lower, list: ir.TypeId, operation: Operation, used: bool) Decision {
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);

    const facts: Facts = .{
        .types = &types,
        .queries = zx.columns.slice(@FieldType(Facts, "queries"), self.state_plan.queries),
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
        .root = @backingInt(list),
        .mode = .Value,
    };

    const input: Query = .{ .source = &facts, .operation = operation, .active = self.state_active, .used = used };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(querying.executeValue, fixed.allocator(), &input) catch @panic("invalid element query");
}

const Frame = struct {
    lower: *Lower,
    body: *Sequence,
    decision: *const Decision,
    name: []const u8,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

fn run(comptime entry: type, self: *Lower, body: *Sequence, list: ir.TypeId, operation: Operation, value: u32, symbol: ?ir.SymbolId) Lower.Error!entry.Output {
    const used = if (symbol) |id| self.used[@backingInt(id)] else false;
    const decision = choice(self, list, operation, used);
    const Request = std.meta.Child(entry.Input);
    const bound = zx.columns.view(std.meta.Child(@FieldType(Request, "choice")), decision);
    var frame: Frame = .{ .lower = self, .body = body, .decision = &decision, .name = if (used) self.names[@backingInt(symbol.?)] else &.{} };

    const input: Request = .{
        .frame = @ptrCast(&frame),
        .choice = &bound,
        .value = value,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input) catch |err| return failure(err);
}

pub fn elementStoredLayout(handle: *anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return storedLayout(frame.lower, frame.decision.*);
}

pub fn storedLayout(self: *Lower, decision: Decision) Lower.Error!u32 {
    return @backingInt(try @import("../types.zig").get(self, self.state_types, @fromBackingInt(decision.type_id)));
}

pub const Bases = std.meta.Child(@FieldType(std.meta.Child(@import("generated_collection_pop").Input), "bases"));

pub const Preparation = struct {
    choice_value: std.meta.Child(@FieldType(Input, "choice")),
    conversion: ?conversion.Input,
    layout: u32,
    pub fn input(self: *const Preparation, comptime Target: type, bases: *const Bases, ast: *const lists.Ast, value: u32, name: []const u8) Target {
        return .{
            .choice = zx.columns.pointer(@FieldType(Target, "choice"), &self.choice_value),
            .conversion = if (self.conversion) |*prepared| zx.columns.pointer(std.meta.Child(@FieldType(Target, "conversion")), prepared) else null,
            .ast = zx.columns.pointer(@FieldType(Target, "ast"), ast),
            .layout = self.layout,
            .value = value,
            .name = name,
            .capture = if (bases.capture) |capture| zx.columns.pointer(std.meta.Child(@FieldType(Target, "capture")), capture) else null,
            .expression_base = bases.expression_base,
            .statement_base = bases.statement_base,
            .field_base = bases.field_base,
            .serial = bases.serial,
        };
    }
};

pub fn prepare(self: *Lower, temporary: std.mem.Allocator, decision: Decision, value: u32, layout: ?u32, capture_value: anytype) Lower.Error!Preparation {
    const capture = if (capture_value) |source| zx.columns.pointer(*const conversion.Capture, source) else null;

    return .{
        .choice_value = zx.columns.view(std.meta.Child(@FieldType(Input, "choice")), decision),
        .conversion = if (layout == null) try conversion.prepareMode(self, temporary, @fromBackingInt(decision.type_id), @fromBackingInt(value), zx.columns.view(conversion.PlanningMode, decision.mode), capture) else null,
        .layout = layout orelse 0,
    };
}

pub fn elementCaptureName(handle: *anyopaque) []const u8 {
    return Frame.borrow(handle).name;
}

pub fn emitElement(handle: *anyopaque, value: u32, layout: ?u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    var boundary: conversion.Capture = undefined;
    const capture_value = conversion.captureBoundary(self, &boundary);
    const preparation = try prepare(self, allocator, frame.decision.*, value, layout, capture_value);
    const ast = lists.borrow(self);
    const bases = context.snapshot(Bases, self);
    const input = preparation.input(Input, &bases, &ast, value, frame.name);
    const output = emitter.executeIn(allocator, &input) catch |err| return failure(err);
    const result = try conversion.apply(self, frame.body, frame.body, output.result);

    if (frame.decision.capture) frame.name = try self.allocator.dupe(u8, output.name);

    return @backingInt(result);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid element emission"),
    };
}
