const std = @import("std");
const Lower = @import("../lower.zig");
const borrow = @import("../expressions/evaluate.zig").borrow;
const Sequence = @import("../../node/blocks.zig").Sequence;
const publication = @import("../construction/publication.zig");
const Error = Lower.Error;

pub fn materializeBorrowedObject(writer: *anyopaque, sequence: *anyopaque, id: u32) Error!u32 {
    const self = borrow(writer);
    const expression = self.program.expression(@fromBackingInt(id));
    const source = expression.value.object;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: @TypeOf(self.cache).SnapshotBuffer = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const saved = try self.cache.snapshot(temporary, source.evaluation);

    defer self.cache.restore(self.allocator, source.evaluation, saved);

    const entry = @import("generated_materialize_borrowed_object");

    const input: std.meta.Child(entry.Input) = .{
        .lowering = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(sequence),
        .type_id = @backingInt(expression.type_id),
        .evaluation = @ptrCast(source.evaluation),
        .fields = source.fields.values[0..source.fields.len],
        .field_indices = source.fields.indices[0..source.fields.len],
        .field_names = self.program.typeOf(expression.type_id).object.names,
        .convert = self.state_active,
        .cache_reads = @ptrCast(&self.cache_reads),
    };

    return entry.executeIn(temporary, &input) catch |err| return publication.failure(err);
}

pub fn borrowedOperandCacheValue(writer: *anyopaque, sequence: *anyopaque, id: u32, value: u32) Error!u32 {
    const self = borrow(writer);
    const body: *Sequence = @ptrCast(@alignCast(sequence));
    const type_id = self.program.expression(@fromBackingInt(id)).type_id;

    return @backingInt(try @import("../state_value/conversion.zig").convert(self, body, type_id, @fromBackingInt(value), .value));
}

pub fn cacheBorrowedOperand(handle: *anyopaque, id: u32, value: u32) Error!void {
    const self = borrow(handle);

    try self.cache.put(self.allocator, @fromBackingInt(id), @fromBackingInt(value));
}
