const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const dense = @import("../../node/import_rows.zig");
const sparse = @import("../../node/import_selected.zig");
const Ast = @import("execution_abi").layouts.@"zig:ast_rows";
const borrow = @import("../expressions/evaluate.zig").borrow;
const publication = @import("../construction/publication.zig");
const failure = publication.failure;
const packSpan = publication.packSpan;

pub fn publishAstStatementBatch(writer: *anyopaque, source: *const Ast.StatementRows, scopes: ?*const Ast.StatementScopes, selection: ?*const Ast.StatementSelection) Lower.Error!u64 {
    const self = borrow(writer);

    if (selection) |batch| {
        const nodes = self.builder.nodes;
        const addresses = view.join(batch.expressions.*, batch.extra.*);

        @import("../../node/import_arms.zig").append(self.allocator, &nodes.arm_columns, batch.arms) catch |err| return failure(err);

        dense.appendBorrowingText(self.allocator, &nodes.expressions, &addresses) catch |err| return failure(err);

        var children = source.*;
        children.tags = batch.children.tags;
        children.offsets = batch.children.offsets;

        sparse.append(self.allocator, &nodes.statements, &children) catch |err| return failure(err);

        const start: u32 = @intCast(nodes.statements.tags.items.len);
        const count: u32 = @intCast(source.tags.len);

        sparse.appendBorrowingText(self.allocator, &nodes.statements, source) catch |err| return failure(err);

        return packSpan(.{ .start = start, .len = count });
    }

    const range = scopes.?;
    const joined = view.join(view.join(source.*, range.variables.*), .{ .scope_start = range.starts, .scope_len = range.counts });

    return packSpan(try self.builder.publishStatements(&joined));
}
