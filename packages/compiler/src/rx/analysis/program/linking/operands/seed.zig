const ir = @import("zx").ir;
const Builder = @import("../../builder.zig");
const Mapping = @import("../../mapping.zig");
const Value = @FieldType(ir.ExpressionRow, "value");
const Storage = ir.ExpressionStorage;
const collections = Storage.collection_payload;
const aggregates = Storage.aggregate_payload;

pub fn append(builder: *Builder, mapping: *const Mapping, source: *const ir.ExpressionTable, index: usize) Builder.Error!usize {
    const storage = &builder.expressions;
    const row = source.at(index);

    try storage.reservePayload(builder.allocator, row);

    return switch (row.value) {
        .list, .tuple, .template => |items| sequence(storage, mapping, @ptrCast(items)),
        .list_operation => |value| collection(storage, mapping, value),
        .transform => |value| transform(storage, mapping, value),
        .scope => |value| scope(storage, mapping, value),
        .match_expr => |value| match(storage, mapping, value),
        .object => |value| object(storage, mapping, value),
        else => unreachable,
    };
}

fn sequence(storage: *Storage, mapping: *const Mapping, source: []const u32) Builder.Error!usize {
    try expressions(mapping, source, tail(&storage.sequence_items, source.len));

    const payload = collections.sequenceHeader(storage, source.len);

    storage.sequence_items.items.len += source.len;

    return payload;
}

fn collection(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "list_operation")) Builder.Error!usize {
    const target = try mapping.seedId(source.target);

    try expressions(mapping, @ptrCast(source.arguments), tail(&storage.collection_arguments, source.arguments.len));

    const payload = collections.collectionHeader(storage, source.kind, target, source.arguments.len);
    storage.collection_arguments.items.len += source.arguments.len;

    return payload;
}

fn transform(storage: *Storage, mapping: *const Mapping, source: ir.Transform) Builder.Error!usize {
    var result = source;
    result.target = try mapping.seedId(source.target);
    result.body = try mapping.seedId(source.body);
    result.initial = if (source.initial) |id| try mapping.seedId(id) else null;

    for (source.parameters, tail(&storage.transform_parameters, source.parameters.len)) |id, *output| {
        output.* = @backingInt(try mapping.seedSymbol(id));
    }

    const payload = collections.transformHeader(storage, result);

    storage.transform_parameters.items.len += source.parameters.len;

    return payload;
}

fn scope(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "scope")) Builder.Error!usize {
    const bindings = source.bindings;
    const result = try mapping.seedId(source.result);

    for (bindings.symbols, tail(&storage.scope_symbols, bindings.len)) |id, *output| {
        output.* = if (id) |value| @backingInt(try mapping.seedSymbol(@fromBackingInt(value))) else null;
    }

    try expressions(mapping, bindings.values, tail(&storage.scope_values, bindings.len));

    @memcpy(tail(&storage.scope_borrows, bindings.len), bindings.borrows);

    const payload = aggregates.scopeHeader(storage, result, bindings.len);
    storage.scope_symbols.items.len += bindings.len;
    storage.scope_values.items.len += bindings.len;
    storage.scope_borrows.items.len += bindings.len;

    return payload;
}

fn match(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "match_expr")) Builder.Error!usize {
    const arms = source.arms;
    const subject = if (source.subject) |id| try mapping.seedId(id) else null;
    const fallback = try mapping.seedId(source.fallback);

    try expressions(mapping, arms.conditions, tail(&storage.match_conditions, arms.len));
    try expressions(mapping, arms.results, tail(&storage.match_results, arms.len));

    const payload = aggregates.matchHeader(storage, subject, fallback, arms.len);
    storage.match_conditions.items.len += arms.len;
    storage.match_results.items.len += arms.len;

    return payload;
}

fn object(storage: *Storage, mapping: *const Mapping, source: @FieldType(Value, "object")) Builder.Error!usize {
    const fields = source.fields;

    try expressions(mapping, fields.values, tail(&storage.object_field_values, fields.len));
    try expressions(mapping, @ptrCast(source.evaluation), tail(&storage.object_evaluation_values, source.evaluation.len));

    @memcpy(tail(&storage.object_field_indices, fields.len), fields.indices);

    const payload = aggregates.objectHeader(storage, fields.len, source.evaluation.len);
    storage.object_field_indices.items.len += fields.len;
    storage.object_field_values.items.len += fields.len;
    storage.object_evaluation_values.items.len += source.evaluation.len;

    return payload;
}

fn expressions(mapping: *const Mapping, source: []const u32, target: []u32) Builder.Error!void {
    for (source, target) |id, *output| output.* = @backingInt(try mapping.seedId(@fromBackingInt(id)));
}

fn tail(list: anytype, count: usize) @TypeOf(list.items) {
    return list.unusedCapacitySlice()[0..count];
}
