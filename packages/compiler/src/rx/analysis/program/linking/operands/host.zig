const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../../builder.zig");
const Mapping = @import("../../mapping.zig");
const abi = @import("../operands.zig");
const Storage = ir.ExpressionStorage;

pub fn sequence(storage: *Storage, allocator: std.mem.Allocator, mapping: *const Mapping, source: *const ir.ExpressionTable, row: u32) Builder.Error!usize {
    const rule = @import("generated_rx_link_sequence_operands");
    const Input = std.meta.Child(rule.Input);
    const fields = &.{ "sequence_first", "sequence_count" };
    const selected = sourceRange(std.meta.Child(@FieldType(Input, "source_range")), source, "sequence", row);

    try storage.reserveColumns(allocator, fields, 1);
    try storage.reserveColumns(allocator, &.{"sequence_items"}, selected.count);

    const target = tail(&storage.sequence_items, selected.count);
    const range = Range.init(storage, "sequence", storage.sequence_items.items.len);

    if (!try abi.invoke(rule, .{
        .source = source.sequence_items,
        .source_range = &selected,
        .mapping = mapping.expressions[0..mapping.available],
        .target = @ptrCast(&target),
        .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
    })) return error.InvalidModule;

    storage.sequence_items.items.len += selected.count;

    return publish(storage, fields);
}

pub fn collection(storage: *Storage, allocator: std.mem.Allocator, mapping: *const Mapping, source: *const ir.ExpressionTable, row: u32) Builder.Error!usize {
    const rule = @import("generated_rx_link_collection_operands");
    const Input = std.meta.Child(rule.Input);
    const fields = &.{ "collection_kinds", "collection_targets", "collection_first", "collection_count" };
    const selected = sourceRange(std.meta.Child(@FieldType(Input, "source_range")), source, "collection", row);

    try storage.reserveColumns(allocator, fields, 1);
    try storage.reserveColumns(allocator, &.{"collection_arguments"}, selected.count);

    const target_arguments = tail(&storage.collection_arguments, selected.count);
    const range = Range.init(storage, "collection", storage.collection_arguments.items.len);
    const kinds = std.mem.sliceAsBytes(tail(&storage.collection_kinds, 1));
    const targets = tail(&storage.collection_targets, 1);

    if (!try abi.invoke(rule, .{
        .target = source.collection_targets[row],
        .kind = @backingInt(source.collection_kinds[row]),
        .mapping = mapping.expressions[0..mapping.available],
        .arguments = source.collection_arguments,
        .source_range = &selected,
        .target_arguments = @ptrCast(&target_arguments),
        .kinds = @ptrCast(&kinds),
        .targets = @ptrCast(&targets),
        .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
    })) return error.InvalidModule;

    storage.collection_arguments.items.len += selected.count;

    return publish(storage, fields);
}

pub fn transform(storage: *Storage, allocator: std.mem.Allocator, mapping: *const Mapping, source: *const ir.ExpressionTable, row: u32) Builder.Error!usize {
    const rule = @import("generated_rx_link_transform_operands");
    const Input = std.meta.Child(rule.Input);
    const fields = &.{ "transform_kinds", "transform_targets", "transform_bodies", "transform_initials", "transform_first", "transform_count" };
    const selected = sourceRange(std.meta.Child(@FieldType(Input, "source_range")), source, "transform", row);

    try storage.reserveColumns(allocator, fields, 1);
    try storage.reserveColumns(allocator, &.{"transform_parameters"}, selected.count);

    const target_parameters = tail(&storage.transform_parameters, selected.count);
    const range = Range.init(storage, "transform", storage.transform_parameters.items.len);
    const kinds = std.mem.sliceAsBytes(tail(&storage.transform_kinds, 1));
    const targets = tail(&storage.transform_targets, 1);
    const bodies = tail(&storage.transform_bodies, 1);
    const initials = tail(&storage.transform_initials, 1);

    if (!try abi.invoke(rule, .{
        .target = source.transform_targets[row],
        .body = source.transform_bodies[row],
        .initial = source.transform_initials[row],
        .kind = @backingInt(source.transform_kinds[row]),
        .mapping = mapping.expressions[0..mapping.available],
        .symbols = &abi.symbolView(std.meta.Child(@FieldType(Input, "symbols")), mapping),
        .parameters = source.transform_parameters,
        .source_range = &selected,
        .target_parameters = @ptrCast(&target_parameters),
        .kinds = @ptrCast(&kinds),
        .targets = @ptrCast(&targets),
        .bodies = @ptrCast(&bodies),
        .initials = @ptrCast(&initials),
        .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
    })) return error.InvalidModule;

    storage.transform_parameters.items.len += selected.count;

    return publish(storage, fields);
}

pub fn scope(storage: *Storage, allocator: std.mem.Allocator, mapping: *const Mapping, source: *const ir.ExpressionTable, row: u32) Builder.Error!usize {
    const rule = @import("generated_rx_link_scope_operands");
    const Input = std.meta.Child(rule.Input);
    const fields = &.{ "scope_results", "scope_first", "scope_count" };
    const bindings = &.{ "scope_symbols", "scope_values", "scope_borrows" };
    const selected = sourceRange(std.meta.Child(@FieldType(Input, "source_range")), source, "scope", row);

    try storage.reserveColumns(allocator, fields, 1);
    try storage.reserveColumns(allocator, bindings, selected.count);

    const target_symbols = tail(&storage.scope_symbols, selected.count);
    const target_values = tail(&storage.scope_values, selected.count);
    const target_borrows = std.mem.sliceAsBytes(tail(&storage.scope_borrows, selected.count));
    const range = Range.init(storage, "scope", storage.scope_symbols.items.len);
    const results = tail(&storage.scope_results, 1);

    if (!try abi.invoke(rule, .{
        .result = source.scope_results[row],
        .mapping = mapping.expressions[0..mapping.available],
        .symbols = &abi.symbolView(std.meta.Child(@FieldType(Input, "symbols")), mapping),
        .binding_symbols = source.scope_symbols,
        .binding_values = source.scope_values,
        .borrows = std.mem.sliceAsBytes(source.scope_borrows),
        .source_range = &selected,
        .target_symbols = @ptrCast(&target_symbols),
        .target_values = @ptrCast(&target_values),
        .target_borrows = @ptrCast(&target_borrows),
        .results = @ptrCast(&results),
        .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
    })) return error.InvalidModule;

    inline for (bindings) |name| @field(storage, name).items.len += selected.count;

    return publish(storage, fields);
}

pub fn match(storage: *Storage, allocator: std.mem.Allocator, mapping: *const Mapping, source: *const ir.ExpressionTable, row: u32) Builder.Error!usize {
    const rule = @import("generated_rx_link_match_operands");
    const Input = std.meta.Child(rule.Input);
    const fields = &.{ "match_subjects", "match_fallbacks", "match_first", "match_count" };
    const arms = &.{ "match_conditions", "match_results" };
    const selected = sourceRange(std.meta.Child(@FieldType(Input, "source_range")), source, "match", row);

    try storage.reserveColumns(allocator, fields, 1);
    try storage.reserveColumns(allocator, arms, selected.count);

    const target_conditions = tail(&storage.match_conditions, selected.count);
    const target_results = tail(&storage.match_results, selected.count);
    const range = Range.init(storage, "match", storage.match_conditions.items.len);
    const subjects = tail(&storage.match_subjects, 1);
    const fallbacks = tail(&storage.match_fallbacks, 1);

    if (!try abi.invoke(rule, .{
        .subject = source.match_subjects[row],
        .fallback = source.match_fallbacks[row],
        .mapping = mapping.expressions[0..mapping.available],
        .conditions = source.match_conditions,
        .results = source.match_results,
        .source_range = &selected,
        .target_conditions = @ptrCast(&target_conditions),
        .target_results = @ptrCast(&target_results),
        .subjects = @ptrCast(&subjects),
        .fallbacks = @ptrCast(&fallbacks),
        .range = &range.view(std.meta.Child(@FieldType(Input, "range"))),
    })) return error.InvalidModule;

    inline for (arms) |name| @field(storage, name).items.len += selected.count;

    return publish(storage, fields);
}

pub fn object(storage: *Storage, allocator: std.mem.Allocator, mapping: *const Mapping, source: *const ir.ExpressionTable, row: u32) Builder.Error!usize {
    const rule = @import("generated_rx_link_object_operands");
    const Input = std.meta.Child(rule.Input);
    const header = &.{ "object_first", "object_count", "object_evaluation_first", "object_evaluation_count" };
    const fields = &.{ "object_field_indices", "object_field_values" };
    const selected = sourceRange(std.meta.Child(@FieldType(Input, "source_fields")), source, "object", row);
    const evaluation = sourceRange(std.meta.Child(@FieldType(Input, "source_evaluation")), source, "object_evaluation", row);

    try storage.reserveColumns(allocator, header, 1);
    try storage.reserveColumns(allocator, fields, selected.count);
    try storage.reserveColumns(allocator, &.{"object_evaluation_values"}, evaluation.count);

    const target_fields = tail(&storage.object_field_values, selected.count);
    const target_evaluation = tail(&storage.object_evaluation_values, evaluation.count);
    const target_indices = std.mem.sliceAsBytes(tail(&storage.object_field_indices, selected.count));
    const field_range = Range.init(storage, "object", storage.object_field_indices.items.len);
    const evaluation_range = Range.init(storage, "object_evaluation", storage.object_evaluation_values.items.len);

    if (!try abi.invoke(rule, .{
        .mapping = mapping.expressions[0..mapping.available],
        .fields = source.object_field_values,
        .indices = std.mem.sliceAsBytes(source.object_field_indices),
        .index_width = @sizeOf(u32),
        .evaluation = source.object_evaluation_values,
        .source_fields = &selected,
        .source_evaluation = &evaluation,
        .target_fields = @ptrCast(&target_fields),
        .target_evaluation = @ptrCast(&target_evaluation),
        .target_indices = @ptrCast(&target_indices),
        .field_range = &field_range.view(std.meta.Child(@FieldType(Input, "field_range"))),
        .evaluation_range = &evaluation_range.view(std.meta.Child(@FieldType(Input, "evaluation_range"))),
    })) return error.InvalidModule;

    inline for (fields) |name| @field(storage, name).items.len += selected.count;

    storage.object_evaluation_values.items.len += evaluation.count;

    return publish(storage, header);
}

const Range = @import("range.zig");

fn sourceRange(comptime Target: type, source: *const ir.ExpressionTable, comptime name: []const u8, row: u32) Target {
    return .{ .first = @field(source, name ++ "_first")[row], .count = @field(source, name ++ "_count")[row] };
}

fn publish(storage: *Storage, comptime fields: []const []const u8) usize {
    const first = @field(storage, fields[0]).items.len;

    inline for (fields) |name| @field(storage, name).items.len += 1;

    return first;
}

fn tail(list: anytype, count: usize) @TypeOf(list.items) {
    return list.unusedCapacitySlice()[0..count];
}
