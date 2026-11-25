const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const Branches = @FieldType(@FieldType(zx.ir.ExpressionRow, "value"), "parallel");

pub fn lower(self: *Lower, type_id: zx.ir.TypeId, branches: Branches) Lower.Error!node.ExpressionId {
    const entry = @import("generated_lower_parallel");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};

    defer scratch.deinit();

    var body = self.builder.statementSequence(scratch.allocator());

    defer body.deinit();

    const output_type = self.program.typeOf(type_id);

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .body = @ptrCast(&body),
        .type_id = @backingInt(type_id),
        .tasks = branches.tasks[0..branches.len],
        .fields = branches.fields[0..branches.len],
        .object_names = if (output_type == .object) output_type.object.names else null,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}
