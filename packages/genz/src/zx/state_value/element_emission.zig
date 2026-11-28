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
const emitter = @import("generated_state_element_emit");
const Call = std.meta.Child(emitter.Input);
const Decision = @typeInfo(@typeInfo(@TypeOf(querying.executeValue)).@"fn".return_type.?).error_union.payload;
pub const StoredTable = @FieldType(Decision, "table");

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
    return @fromBackingInt((try run(self, body, list, .Read, @backingInt(value), null)).root);
}

pub fn write(self: *Lower, body: *Sequence, list: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return @fromBackingInt((try run(self, body, list, .Write, @backingInt(value), null)).root);
}

pub fn captureName(self: *Lower, body: *Sequence, list: ir.TypeId, symbol: ir.SymbolId) Lower.Error![]const u8 {
    return (try run(self, body, list, .Capture, 0, symbol)).name;
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

fn run(self: *Lower, body: *Sequence, list: ir.TypeId, operation: Operation, value: u32, symbol: ?ir.SymbolId) Lower.Error!emitter.Output {
    const used = if (symbol) |id| self.used[@backingInt(id)] else false;
    const decision = choice(self, list, operation, used);
    const bound = zx.columns.view(std.meta.Child(@FieldType(Call, "choice")), decision);
    const name = if (used) self.names[@backingInt(symbol.?)] else &.{};
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    var boundary: conversion.Capture = undefined;
    const prepared: ?conversion.Input = if (!decision.passthrough and !decision.discard and !decision.stored) try conversion.prepareMode(self, allocator, @fromBackingInt(decision.type_id), @fromBackingInt(value), zx.columns.view(conversion.PlanningMode, decision.mode), conversion.captureBoundary(self, &boundary)) else null;

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .choice = &bound,
        .conversion = if (prepared) |*item| zx.columns.pointer(std.meta.Child(@FieldType(Call, "conversion")), item) else null,
        .value = value,
        .name = name,
    };

    return emitter.executeIn(allocator, &call) catch |err| return failure(err);
}

pub fn storedLayout(self: *Lower, decision: Decision) Lower.Error!u32 {
    return @backingInt(try @import("../types.zig").get(self, self.state_types, @fromBackingInt(decision.type_id)));
}

const PopInput = std.meta.Child(@FieldType(std.meta.Child(@import("generated_collection_pop").Input), "pop"));
pub const Bases = std.meta.Child(@FieldType(PopInput, "bases"));
const PopElement = std.meta.Child(@typeInfo(@FieldType(PopInput, "element")).optional.child);

pub const Preparation = struct {
    choice_value: std.meta.Child(@FieldType(PopElement, "choice")),
    conversion: ?conversion.Input,
    layout: u32,
    pub fn input(self: *const Preparation, comptime Target: type, bases: *const Bases, value: u32, name: []const u8) Target {
        return .{
            .choice = zx.columns.pointer(@FieldType(Target, "choice"), &self.choice_value),
            .conversion = if (self.conversion) |*prepared| zx.columns.pointer(std.meta.Child(@FieldType(Target, "conversion")), prepared) else null,
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
        .choice_value = zx.columns.view(std.meta.Child(@FieldType(PopElement, "choice")), decision),
        .conversion = if (layout == null) try conversion.prepareMode(self, temporary, @fromBackingInt(decision.type_id), @fromBackingInt(value), zx.columns.view(conversion.PlanningMode, decision.mode), capture) else null,
        .layout = layout orelse 0,
    };
}

pub fn borrowSource(comptime Source: type, self: *const Lower, types: *std.meta.Child(@FieldType(Source, "types"))) Source {
    types.* = ir.TypeTable.borrow(@TypeOf(types.*), self.program.types);

    return .{
        .types = types,
        .active = self.state_active,
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
    };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid element emission"),
    };
}
