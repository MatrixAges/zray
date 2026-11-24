const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const Frame = @import("workflow.zig").Frame;
const Api = @import("../expressions/evaluate.zig").Api;
const emission = @import("emission.zig");
const entry = @import("generated_emit_collection_rows");
const Error = Lower.Error;

pub fn collectionCompare(handle: *const anyopaque) Error![]const u8 {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const child = self.program.typeOf(frame.source_type).list;
    var found = false;

    for (self.comparisons.items) |previous| {
        if (previous == child) found = true;
    }

    if (!found) try self.comparisons.append(self.allocator, child);

    return @import("../comparison.zig").name(self, child);
}

pub fn collectionMinimum(handle: *const anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const context = frame.lower.loop_fields orelse return null;
    const value = try context.minimum(frame.lower, frame.id) orelse return null;

    return @backingInt(value);
}

pub fn emitCollectionRows(handle: *const anyopaque, rows: *const Api.CollectionRows, minimum: ?u32, compare: ?[]const u8) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const Input = std.meta.Child(entry.Input);
    const selected = @import("../state_value/list.zig").selected(self, frame.source_type);
    const layout = if (selected) try @import("../types.zig").get(self, self.state_types, frame.source_type) else null;
    const ast = zx.columns.view(std.meta.Child(@FieldType(Input, "ast")), @import("../state_value/list_emission.zig").borrow(self));

    const bases: std.meta.Child(@FieldType(Input, "bases")) = .{
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{
        .kind = @fromBackingInt(@backingInt(frame.kind)),
        .items = rows.items,
        .value = rows.value,
        .header = rows.header,
        .element = rows.element,
        .length = rows.length,
        .unit = rows.unit,
        .first = rows.first,
        .second = rows.second,
        .third = rows.third,
        .minimum = minimum,
        .compare = compare orelse &.{},
        .selected = selected,
        .layout = if (layout) |expression| @backingInt(expression) else 0,
        .in_place = frame.flags.in_place,
        .grow = frame.flags.grow,
        .frontier = frame.flags.frontier,
        .lazy = frame.flags.lazy,
        .retract = frame.flags.retract,
        .removed_only = frame.removed_only,
        .shared = self.shared_types,
        .ast = &ast,
        .bases = &bases,
    };

    const output = entry.executeIn(frame.temporary, &input) catch |err| return emission.failure(err);

    return @backingInt(try emission.apply(self, &frame.body, output));
}

pub fn emitCollectionPop(handle: *const anyopaque, items: u32, value: u32, header: u32, element: u32, length: u32) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("pop.zig").lower(frame.lower, &frame.body, .{
        .type_id = frame.source_type,
        .result_type = frame.result_type,
        .items = @fromBackingInt(items),
        .value = @fromBackingInt(value),
        .header = @fromBackingInt(header),
        .element = @fromBackingInt(element),
        .length = @fromBackingInt(length),
        .retract = frame.flags.retract,
    }));
}
