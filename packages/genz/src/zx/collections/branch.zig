const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const evaluation = @import("../expressions/evaluate.zig");
const Ast = @import("execution_abi").layouts.@"zig:ast_rows";
const publication = @import("../construction/publication.zig");
const entry = @import("generated_emit_collection_rows");
const Error = Lower.Error;

pub fn collectionCompare(frame: *anyopaque, source_type: u32) Error![]const u8 {
    const self = evaluation.borrow(frame);
    const child = self.program.typeOf(@fromBackingInt(source_type)).list;
    var found = false;

    for (self.comparisons.items) |previous| {
        if (previous == child) found = true;
    }

    if (!found) try self.comparisons.append(self.allocator, child);

    return @import("../comparison.zig").name(self, child);
}

pub fn collectionMinimum(frame: *anyopaque, id: u32) Error!?u32 {
    const lowering = evaluation.borrow(frame);
    const context = lowering.loop_fields orelse return null;
    const value = try context.minimum(lowering, @fromBackingInt(id)) orelse return null;

    return @backingInt(value);
}

pub fn emitCollectionRows(
    allocator: std.mem.Allocator,
    frame: *anyopaque,
    body: *anyopaque,
    id: u32,
    source_type: u32,
    removed_only: bool,
    rows: *const Ast.CollectionRows,
    minimum: ?u32,
    compare: ?[]const u8,
) Error!u32 {
    const self = evaluation.borrow(frame);
    const expression: zx.ir.ExprId = @fromBackingInt(id);
    const operation = self.program.expression(expression).value.list_operation;
    const flags = self.plan.get(expression);
    const list_type: zx.ir.TypeId = @fromBackingInt(source_type);
    const Call = std.meta.Child(entry.Input);
    const Input = std.meta.Child(@FieldType(Call, "rows"));
    const selected = @import("../state_value/list.zig").selected(self, list_type);
    const layout = if (selected) try @import("../types.zig").get(self, self.state_types, list_type) else null;
    const ast = zx.columns.view(std.meta.Child(@FieldType(Input, "ast")), @import("../state_value/list_emission.zig").borrow(self));
    const bases = @import("../construction/context.zig").snapshot(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .kind = @fromBackingInt(@backingInt(operation.kind)),
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
        .layout = if (layout) |type_expr| @backingInt(type_expr) else 0,
        .in_place = flags.in_place,
        .grow = flags.grow,
        .frontier = flags.frontier,
        .lazy = flags.lazy,
        .retract = flags.retract,
        .removed_only = removed_only,
        .shared = self.shared_types,
        .ast = &ast,
        .bases = &bases,
    };

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .rows = &input,
    };

    return entry.executeIn(allocator, &call) catch |err| return publication.failure(err);
}

pub fn emitCollectionPop(
    frame: *anyopaque,
    body: *anyopaque,
    id: u32,
    source_type: u32,
    result_type: u32,
    items: u32,
    value: u32,
    header: u32,
    element: u32,
    length: u32,
) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try @import("pop.zig").lower(lowering, sequence, .{
        .type_id = @fromBackingInt(source_type),
        .result_type = @fromBackingInt(result_type),
        .items = @fromBackingInt(items),
        .value = @fromBackingInt(value),
        .header = @fromBackingInt(header),
        .element = @fromBackingInt(element),
        .length = @fromBackingInt(length),
        .retract = lowering.plan.get(@fromBackingInt(id)).retract,
    }));
}
