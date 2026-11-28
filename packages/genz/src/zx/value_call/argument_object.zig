const std = @import("std");
const Lower = @import("../lower.zig");
const borrow = @import("../expressions/evaluate.zig").borrow;
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
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .lowering = @ptrCast(self),
        .writer = @ptrCast(self),
        .sequence = @ptrCast(sequence),
        .type_id = @backingInt(expression.type_id),
        .evaluation = @ptrCast(source.evaluation),
        .fields = source.fields.values[0..source.fields.len],
        .field_indices = source.fields.indices[0..source.fields.len],
        .field_names = self.program.typeOf(expression.type_id).object.names,
        .state_active = self.state_active,
        .queries = @import("zx").columns.slice(@FieldType(Input, "queries"), self.state_plan.queries),
        .expression_types = self.program.expressions.types,
        .cache_reads = self.cache_reads,
    };

    return entry.executeIn(temporary, &input) catch |err| return publication.failure(err);
}

pub fn cacheLoweredOperand(handle: *anyopaque, id: u32, value: u32) Error!void {
    const self = borrow(handle);

    try self.cache.put(self.allocator, @fromBackingInt(id), @fromBackingInt(value));
}
