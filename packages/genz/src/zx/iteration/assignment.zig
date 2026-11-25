const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub const Write = struct {
    type_id: ir.TypeId,
    active: bool,
    target: node.ExpressionId,
    value: node.ExpressionId,
    mark: ?@FieldType(node.Statement, "assignment"),
};

pub fn lower(self: *Lower, write: Write) Lower.Error!u32 {
    const entry = @import("generated_iteration_assignment");
    const Input = std.meta.Child(entry.Input);
    const Facts = std.meta.Child(@FieldType(Input, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const facts: Facts = .{ .types = &types, .selected = self.state_plan.selected };
    const Mark = std.meta.Child(@typeInfo(@FieldType(Input, "mark")).optional.child);

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .facts = &facts,
        .active = write.active,
        .type_id = @backingInt(write.type_id),
        .target = @backingInt(write.target),
        .value = @backingInt(write.value),
        .mark = if (write.mark) |value| &@as(Mark, .{ .target = @backingInt(value.target), .value = @backingInt(value.value) }) else null,
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .serial = self.serial,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    return entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
