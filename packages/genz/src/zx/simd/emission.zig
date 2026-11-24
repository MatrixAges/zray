const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;
const publication = @import("../construction/publication.zig");
const entry = @import("generated_execute_simd");
const Input = std.meta.Child(entry.Input);
const Analysis = std.meta.Child(@FieldType(Input, "analysis"));

pub fn lower(self: *Lower, id: ir.ExprId, consumer: ?Consumer) Lower.Error!?node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const owner = scratch.allocator();
    const program: *const ir.Program = &self.program;
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Analysis, "types")), program.types);

    const analysis: Analysis = .{
        .types = &types,
        .expressions = zx.columns.pointer(@FieldType(Analysis, "expressions"), &program.expressions),
        .subject = @backingInt(id),
        .consumer = if (consumer) |value| &.{ .symbol = @backingInt(value.symbol), .result = @backingInt(value.result) } else null,
    };

    var origin: publication.OriginBuffer = .{};
    var literals: []u32 = &.{};

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .owner = @ptrCast(&owner),
        .literals = @ptrCast(&literals),
        .analysis = &analysis,
    };

    const result = entry.executeIn(owner, &input) catch |err| return publication.failure(err);

    return if (result) |value| @fromBackingInt(value) else null;
}
