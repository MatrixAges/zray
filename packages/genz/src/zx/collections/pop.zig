const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const elements = @import("../state_value/element_emission.zig");
const conversion = @import("../state_value/conversion_emission.zig");

pub const Request = struct {
    type_id: ir.TypeId,
    result_type: ir.TypeId,
    items: node.ExpressionId,
    value: node.ExpressionId,
    header: node.ExpressionId,
    element: node.ExpressionId,
    length: node.ExpressionId,
    retract: bool,
};

pub fn lower(self: *Lower, body: *@import("../../node/blocks.zig").Sequence, args: Request) Lower.Error!node.ExpressionId {
    const entry = @import("generated_collection_pop");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const Element = std.meta.Child(@typeInfo(@FieldType(Input, "element")).optional.child);
    const serial = self.serial;
    const declarations = self.task_declarations.count();
    const statements = self.builder.nodes.statements.tags.items.len;
    const dynamic = @import("../state_value/list.zig").selected(self, args.type_id);
    const layout = if (dynamic) try @import("../types.zig").get(self, self.state_types, args.type_id) else null;
    const decision = elements.choice(self, args.type_id, .Read, false);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const element_layout = if (!decision.passthrough and decision.stored) try elements.storedLayout(self, decision) else null;
    var boundary: conversion.Capture = undefined;
    const capture = conversion.captureBoundary(self, &boundary);
    const preparation = if (!decision.passthrough) try elements.prepare(self, memory.allocator(), decision, 0, element_layout, capture) else null;
    const bases = @import("../construction/context.zig").snapshot(Bases, self);
    const ast = @import("../state_value/list_emission.zig").borrow(self);
    const origin_ast = @import("../construction/ast.zig").borrow(std.meta.Child(@FieldType(Input, "origin_ast")), self);
    const selected_result = self.state_active and self.state_plan.selected[@backingInt(args.result_type)];

    std.debug.assert(serial == self.serial and declarations == self.task_declarations.count());
    std.debug.assert(statements == self.builder.nodes.statements.tags.items.len);

    const element: Element = if (preparation) |*prepared| prepared.input(Element, &bases, &ast, 0, &.{}) else undefined;

    const input: Input = .{
        .items = @backingInt(args.items),
        .value = @backingInt(args.value),
        .header = @backingInt(args.header),
        .element_type = @backingInt(args.element),
        .length = @backingInt(args.length),
        .dynamic = dynamic,
        .layout = if (layout) |value| @backingInt(value) else 0,
        .retract = args.retract,
        .shared = self.shared_types,
        .element = if (!decision.passthrough) &element else null,
        .origin = selected_result,
        .arity = self.program.typeOf(args.result_type).tuple.len,
        .origin_ast = &origin_ast,
        .ast = @import("zx").columns.pointer(@FieldType(Input, "ast"), &ast),
        .bases = &bases,
    };

    const output = entry.executeIn(memory.allocator(), &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return conversion.apply(self, body, body, output);
}
