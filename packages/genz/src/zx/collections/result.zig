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
    capture: ?*const conversion.Capture,
    members: []Member,
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
    const bases = @import("../construction/context.zig").snapshot(Bases, self);

    const storage: Storage = .{
        .lower = self,
        .temporary = temporary,
        .capture = conversion.captureBoundary(self, &boundary),
        .members = members,
    };

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(&frame.body),
        .preparation = &.{
            .frame = @ptrCast(&storage),
            .types = types.values[0..types.len],
            .queries = zx.columns.slice(@FieldType(Preparation, "queries"), self.state_plan.queries),
        },
        .source = &.{ .value = @backingInt(value), .members = members, .bases = &bases },
    };

    const root = entry.executeIn(temporary, &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(root);
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
