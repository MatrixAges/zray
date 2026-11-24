const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const conversion = @import("../state_value/conversion_emission.zig");
const Collection = @import("workflow.zig").Frame;
const entry = @import("generated_collection_result");
const Input = std.meta.Child(entry.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));
const Preparation = std.meta.Child(@FieldType(Input, "preparation"));
const Bases = std.meta.Child(@FieldType(Source, "bases"));
const Member = std.meta.Child(@FieldType(Source, "members"));

const Storage = struct {
    lower: *Lower,
    temporary: std.mem.Allocator,
    bases: *Bases,
    capture: ?*const conversion.Capture,
    members: []Member,
    declarations: usize,
    references: usize,
    fn borrow(frame: *const anyopaque) *const Storage {
        return @ptrCast(@alignCast(frame));
    }
};

pub fn lower(frame: *Collection, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const self = frame.lower;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const types = self.program.typeOf(frame.operation.?.result_type).tuple;
    const members = try temporary.alloc(Member, types.len);
    var boundary: conversion.Capture = undefined;
    var bases = @import("../construction/context.zig").snapshot(Bases, self);

    const storage: Storage = .{
        .lower = self,
        .temporary = temporary,
        .bases = &bases,
        .capture = conversion.captureBoundary(self, &boundary),
        .members = members,
        .declarations = self.task_declarations.count(),
        .references = self.referenceBatches(),
    };

    const input: Input = .{
        .preparation = &.{
            .frame = @ptrCast(&storage),
            .types = types.values[0..types.len],
            .queries = zx.columns.slice(@FieldType(Preparation, "queries"), self.state_plan.queries),
        },
        .source = &.{ .value = @backingInt(value), .members = members, .bases = &bases },
    };

    const output = entry.executeIn(temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return conversion.apply(self, &frame.body, &frame.body, output);
}

pub fn prepareCollectionMember(handle: *const anyopaque, index: u64, type_id: ?u32) Lower.Error!void {
    const storage = Storage.borrow(handle);
    const temporary = storage.temporary;

    storage.members[@intCast(index)] = if (type_id) |id| member: {
        const Prepared = std.meta.Child(std.meta.Child(Member));
        const prepared = try temporary.create(Prepared);
        prepared.* = zx.columns.view(Prepared, try conversion.prepareFor(storage.lower, temporary, @fromBackingInt(id), @fromBackingInt(0), .pointer, storage.capture));

        break :member prepared;
    } else null;
}

pub fn refreshCollectionResultBases(handle: *const anyopaque) void {
    const storage = Storage.borrow(handle);
    const self = storage.lower;
    const bases = storage.bases;

    std.debug.assert(bases.serial == self.serial and storage.declarations == self.task_declarations.count());
    std.debug.assert(bases.statement_base == self.builder.nodes.statements.tags.items.len);
    std.debug.assert(storage.references == self.referenceBatches());

    bases.expression_base = @intCast(self.builder.nodes.expressions.tags.items.len);
    bases.field_base = @intCast(self.builder.nodes.field_columns.count());
}
