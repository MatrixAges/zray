const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const conversion = @import("../state_value/conversion_emission.zig");

pub fn lower(self: *Lower, body: *@import("../../node/blocks.zig").Sequence, type_id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const entry = @import("generated_collection_result");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const Member = std.meta.Child(@FieldType(Input, "members"));
    const Prepared = std.meta.Child(std.meta.Child(Member));
    const serial = self.serial;
    const declarations = self.task_declarations.count();
    const statements = self.builder.nodes.statements.tags.items.len;
    const storage = self.referenceBatches();
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    var boundary: conversion.Capture = undefined;
    const capture = conversion.captureBoundary(self, &boundary);
    const types = self.program.typeOf(type_id).tuple;
    const members = try temporary.alloc(Member, types.len);

    for (members, 0..) |*member, index| {
        const id = types.at(index);

        if (!self.state_plan.represented(self.program, id)) {
            member.* = null;

            continue;
        }

        const prepared = try temporary.create(Prepared);

        prepared.* = zx.columns.view(Prepared, try conversion.prepareFor(self, temporary, id, @fromBackingInt(0), .pointer, capture));
        member.* = prepared;
    }

    std.debug.assert(serial == self.serial and declarations == self.task_declarations.count());
    std.debug.assert(statements == self.builder.nodes.statements.tags.items.len);
    std.debug.assert(storage == self.referenceBatches());

    const bases = @import("../construction/context.zig").snapshot(Bases, self);

    const input: Input = .{
        .value = @backingInt(value),
        .members = members,
        .bases = &bases,
    };

    const output = entry.executeIn(temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return conversion.apply(self, body, body, output);
}
