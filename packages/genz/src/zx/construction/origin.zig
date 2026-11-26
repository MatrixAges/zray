const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const publication = @import("publication.zig");

pub fn lower(self: *Lower, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const generated = @import("generated_tuple_origin");
    const Input = std.meta.Child(generated.Input);
    const Origin = std.meta.Child(@FieldType(Input, "origin"));
    const kind = self.program.typeOf(id);
    const ast = @import("ast.zig").borrow(std.meta.Child(@FieldType(Origin, "table")), self);

    const origin: Origin = .{
        .table = &ast,
        .value = @backingInt(value),
        .active = self.state_active,
        .selected = if (self.state_active) self.state_plan.selected[@backingInt(id)] else false,
        .is_tuple = kind == .tuple,
        .arity = if (kind == .tuple) kind.tuple.len else 0,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    const input: Input = .{
        .writer = @ptrCast(self),
        .origin = &origin,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const root = generated.executeIn(buffered.allocator(), &input) catch |err| return publication.failure(err);

    return @fromBackingInt(root);
}
