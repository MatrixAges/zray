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
const Ast = @import("execution_abi").layouts.@"zig:ast_rows";

const Host = struct {
    lowering: *Lower,
    pub fn commit(self: Host, pending: anytype) Lower.Error!void {
        const state = pending.store_0 orelse return;
        const append = state.append orelse unreachable;

        if (append.expressions) |rows| {
            const source = zx.columns.pointer(*const Ast.ExpressionRows, rows);

            try publication.appendExpressionRows(self.lowering, source, null, .Owned);
        }

        if (append.statements) |rows| {
            const source = zx.columns.pointer(*const Ast.StatementRows, rows);

            try publication.appendStatementRows(self.lowering, source, null, .Owned);
        }

        if (append.serial) |serial| {
            @import("../expressions/evaluate/native.zig").finishGeneratedAst(self.lowering, serial, append.uses_allocator);
        }
    }
};

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

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .analysis = &analysis,
    };

    const result = entry.executeIn(owner, &input, Host{ .lowering = self }) catch |err| return publication.failure(err);

    return if (result) |value| @fromBackingInt(value) else null;
}
