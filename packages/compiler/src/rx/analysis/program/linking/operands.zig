const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");
const enabled = @import("rx_options").generated_graph;
const Value = @FieldType(ir.ExpressionRow, "value");
const Storage = ir.ExpressionStorage;
const collections = Storage.collection_payload;
const aggregates = Storage.aggregate_payload;

pub fn sequence(storage: *Storage, mapping: *const Mapping, source: []const u32) Builder.Error!usize {
    const target = tail(&storage.sequence_items, source.len);

    const payload = if (comptime enabled) generated: {
        const rule = @import("generated_rx_link_sequence_operands");
        const Input = std.meta.Child(rule.Input);
        const range = Range.init(storage, "sequence", storage.sequence_items.items.len);

        if (!try invoke(rule, .{
            .source = source,
            .mapping = mapping.expressions[0..mapping.available],
            .target = @ptrCast(&target),
            .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
        })) return error.InvalidModule;

        break :generated publish(storage, &.{ "sequence_first", "sequence_count" });
    } else seed: {
        try expressions(mapping, source, target);

        break :seed collections.sequenceHeader(storage, source.len);
    };

    storage.sequence_items.items.len += source.len;

    return payload;
}

pub fn collection(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "list_operation"), kind: u8) Builder.Error!usize {
    const target_arguments = tail(&storage.collection_arguments, source.arguments.len);

    const payload = if (comptime enabled) generated: {
        const rule = @import("generated_rx_link_collection_operands");
        const Input = std.meta.Child(rule.Input);
        const range = Range.init(storage, "collection", storage.collection_arguments.items.len);
        const kinds = std.mem.sliceAsBytes(tail(&storage.collection_kinds, 1));
        const targets = tail(&storage.collection_targets, 1);

        if (!try invoke(rule, .{
            .target = @backingInt(source.target),
            .kind = kind,
            .mapping = mapping.expressions[0..mapping.available],
            .arguments = @ptrCast(source.arguments),
            .target_arguments = @ptrCast(&target_arguments),
            .kinds = @ptrCast(&kinds),
            .targets = @ptrCast(&targets),
            .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
        })) return error.InvalidModule;

        break :generated publish(storage, &.{ "collection_first", "collection_count", "collection_kinds", "collection_targets" });
    } else seed: {
        const target = try mapping.seedId(source.target);

        try expressions(mapping, @ptrCast(source.arguments), target_arguments);

        break :seed collections.collectionHeader(storage, source.kind, target, source.arguments.len);
    };

    storage.collection_arguments.items.len += source.arguments.len;

    return payload;
}

pub fn transform(storage: *Storage, mapping: *const Mapping, source: ir.Transform, kind: u8) Builder.Error!usize {
    const target_parameters = tail(&storage.transform_parameters, source.parameters.len);

    const payload = if (comptime enabled) generated: {
        const rule = @import("generated_rx_link_transform_operands");
        const Input = std.meta.Child(rule.Input);
        const range = Range.init(storage, "transform", storage.transform_parameters.items.len);
        const kinds = std.mem.sliceAsBytes(tail(&storage.transform_kinds, 1));
        const targets = tail(&storage.transform_targets, 1);
        const bodies = tail(&storage.transform_bodies, 1);
        const initials = tail(&storage.transform_initials, 1);

        if (!try invoke(rule, .{
            .target = @backingInt(source.target),
            .body = @backingInt(source.body),
            .initial = if (source.initial) |id| @backingInt(id) else null,
            .kind = kind,
            .mapping = mapping.expressions[0..mapping.available],
            .symbols = &symbolView(std.meta.Child(@FieldType(Input, "symbols")), mapping),
            .parameters = @ptrCast(source.parameters),
            .target_parameters = @ptrCast(&target_parameters),
            .kinds = @ptrCast(&kinds),
            .targets = @ptrCast(&targets),
            .bodies = @ptrCast(&bodies),
            .initials = @ptrCast(&initials),
            .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
        })) return error.InvalidModule;

        break :generated publish(storage, &.{ "transform_first", "transform_count", "transform_kinds", "transform_targets", "transform_bodies", "transform_initials" });
    } else seed: {
        var result = source;

        result.target = try mapping.seedId(source.target);
        result.body = try mapping.seedId(source.body);
        result.initial = if (source.initial) |id| try mapping.seedId(id) else null;

        for (source.parameters, target_parameters) |id, *output| {
            output.* = @backingInt(try mapping.seedSymbol(id));
        }

        break :seed collections.transformHeader(storage, result);
    };

    storage.transform_parameters.items.len += source.parameters.len;

    return payload;
}

pub fn scope(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "scope")) Builder.Error!usize {
    const bindings = source.bindings;
    const target_symbols = tail(&storage.scope_symbols, bindings.len);
    const target_values = tail(&storage.scope_values, bindings.len);
    const target_borrows = tail(&storage.scope_borrows, bindings.len);

    const payload = if (comptime enabled) generated: {
        const rule = @import("generated_rx_link_scope_operands");
        const Input = std.meta.Child(rule.Input);
        const range = Range.init(storage, "scope", storage.scope_symbols.items.len);
        const borrows = std.mem.sliceAsBytes(target_borrows);
        const results = tail(&storage.scope_results, 1);

        if (!try invoke(rule, .{
            .result = @backingInt(source.result),
            .mapping = mapping.expressions[0..mapping.available],
            .symbols = &symbolView(std.meta.Child(@FieldType(Input, "symbols")), mapping),
            .binding_symbols = bindings.symbols,
            .binding_values = bindings.values,
            .borrows = std.mem.sliceAsBytes(bindings.borrows),
            .target_symbols = @ptrCast(&target_symbols),
            .target_values = @ptrCast(&target_values),
            .target_borrows = @ptrCast(&borrows),
            .results = @ptrCast(&results),
            .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
        })) return error.InvalidModule;

        break :generated publish(storage, &.{ "scope_first", "scope_count", "scope_results" });
    } else seed: {
        const result = try mapping.seedId(source.result);

        for (bindings.symbols, target_symbols) |id, *output| {
            output.* = if (id) |value| @backingInt(try mapping.seedSymbol(@fromBackingInt(value))) else null;
        }

        try expressions(mapping, bindings.values, target_values);

        @memcpy(target_borrows, bindings.borrows);

        break :seed aggregates.scopeHeader(storage, result, bindings.len);
    };

    storage.scope_symbols.items.len += bindings.len;
    storage.scope_values.items.len += bindings.len;
    storage.scope_borrows.items.len += bindings.len;

    return payload;
}

pub fn match(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "match_expr")) Builder.Error!usize {
    const arms = source.arms;
    const target_conditions = tail(&storage.match_conditions, arms.len);
    const target_results = tail(&storage.match_results, arms.len);

    const payload = if (comptime enabled) generated: {
        const rule = @import("generated_rx_link_match_operands");
        const Input = std.meta.Child(rule.Input);
        const range = Range.init(storage, "match", storage.match_conditions.items.len);
        const subjects = tail(&storage.match_subjects, 1);
        const fallbacks = tail(&storage.match_fallbacks, 1);

        if (!try invoke(rule, .{
            .subject = if (source.subject) |id| @backingInt(id) else null,
            .fallback = @backingInt(source.fallback),
            .mapping = mapping.expressions[0..mapping.available],
            .conditions = arms.conditions,
            .results = arms.results,
            .target_conditions = @ptrCast(&target_conditions),
            .target_results = @ptrCast(&target_results),
            .subjects = @ptrCast(&subjects),
            .fallbacks = @ptrCast(&fallbacks),
            .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
        })) return error.InvalidModule;

        break :generated publish(storage, &.{ "match_first", "match_count", "match_subjects", "match_fallbacks" });
    } else seed: {
        const subject = if (source.subject) |id| try mapping.seedId(id) else null;
        const fallback = try mapping.seedId(source.fallback);

        try expressions(mapping, arms.conditions, target_conditions);
        try expressions(mapping, arms.results, target_results);

        break :seed aggregates.matchHeader(storage, subject, fallback, arms.len);
    };

    storage.match_conditions.items.len += arms.len;
    storage.match_results.items.len += arms.len;

    return payload;
}

pub fn object(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "object")) Builder.Error!usize {
    const fields = source.fields;
    const target_fields = tail(&storage.object_field_values, fields.len);
    const target_evaluation = tail(&storage.object_evaluation_values, source.evaluation.len);
    const target_indices = tail(&storage.object_field_indices, fields.len);

    const payload = if (comptime enabled) generated: {
        const rule = @import("generated_rx_link_object_operands");
        const Input = std.meta.Child(rule.Input);
        const field_range = Range.init(storage, "object", storage.object_field_indices.items.len);
        const evaluation_range = Range.init(storage, "object_evaluation", storage.object_evaluation_values.items.len);
        const indices = std.mem.sliceAsBytes(target_indices);

        if (!try invoke(rule, .{
            .mapping = mapping.expressions[0..mapping.available],
            .fields = fields.values,
            .indices = std.mem.sliceAsBytes(fields.indices),
            .evaluation = @ptrCast(source.evaluation),
            .target_fields = @ptrCast(&target_fields),
            .target_evaluation = @ptrCast(&target_evaluation),
            .target_indices = @ptrCast(&indices),
            .field_range = &field_range.view(std.meta.Child(@FieldType(Input, "field_range"))),
            .evaluation_range = &evaluation_range.view(std.meta.Child(@FieldType(Input, "evaluation_range"))),
        })) return error.InvalidModule;

        break :generated publish(storage, &.{ "object_first", "object_count", "object_evaluation_first", "object_evaluation_count" });
    } else seed: {
        try expressions(mapping, fields.values, target_fields);
        try expressions(mapping, @ptrCast(source.evaluation), target_evaluation);

        @memcpy(target_indices, fields.indices);

        break :seed aggregates.objectHeader(storage, fields.len, source.evaluation.len);
    };

    storage.object_field_indices.items.len += fields.len;
    storage.object_field_values.items.len += fields.len;
    storage.object_evaluation_values.items.len += source.evaluation.len;

    return payload;
}

const Range = struct {
    firsts: []u32,
    counts: []u32,
    first: u32,
    fn init(storage: *Storage, comptime name: []const u8, first: usize) Range {
        return .{
            .firsts = tail(&@field(storage, name ++ "_first"), 1),
            .counts = tail(&@field(storage, name ++ "_count"), 1),
            .first = @intCast(first),
        };
    }
    fn view(self: *const Range, comptime Target: type) Target {
        return .{ .firsts = @ptrCast(&self.firsts), .counts = @ptrCast(&self.counts), .first = self.first };
    }
};

fn publish(storage: *Storage, comptime fields: []const []const u8) usize {
    const first = @field(storage, fields[0]).items.len;

    inline for (fields) |name| @field(storage, name).items.len += 1;

    return first;
}

fn tail(list: anytype, count: usize) @TypeOf(list.items) {
    return list.unusedCapacitySlice()[0..count];
}

fn expressions(mapping: *const Mapping, source: []const u32, target: []u32) Builder.Error!void {
    for (source, target) |id, *output| output.* = @backingInt(try mapping.seedId(@fromBackingInt(id)));
}

pub fn symbolView(comptime Target: type, mapping: *const Mapping) Target {
    return .{ .bindings = mapping.bindings, .locals_base = mapping.locals_base, .count = mapping.symbol_count };
}

pub fn invoke(comptime rule: type, input: std.meta.Child(rule.Input)) Builder.Error!@typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.IndexOutOfBounds, error.IntegerOverflow => return error.InvalidModule,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
