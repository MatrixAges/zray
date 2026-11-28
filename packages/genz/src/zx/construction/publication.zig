const std = @import("std");
const Lower = @import("../lower.zig");
const blocks = @import("../../node/blocks.zig");
const node = @import("../../node.zig");
const Sequence = blocks.Sequence;
const view = @import("../../node/view.zig");
const dense = @import("../../node/import_rows.zig");
const sparse = @import("../../node/import_selected.zig");
const statements = @import("../../node/import_statements.zig");
const fields = @import("../../node/import_fields.zig");
const Ast = @import("execution_abi").layouts.@"zig:ast_rows";
const borrow = @import("../expressions/evaluate.zig").borrow;

pub fn readAstOrigin(allocator: std.mem.Allocator, writer: *anyopaque) Lower.Error!*const Ast.AstOrigin {
    const self = borrow(writer);
    const origin = try allocator.create(Ast.AstOrigin);

    const snapshot = if (self.capture) |capture| captured: {
        const result = try allocator.create(Ast.AstCapture);
        result.* = .{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) };

        break :captured result;
    } else null;

    origin.* = .{
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
        .capture = snapshot,
    };

    return origin;
}

pub fn appendExpressionRows(writer: *anyopaque, source: *const Ast.ExpressionRows, forms: ?*const Ast.ExpressionForms, mode: Ast.AstPayloadOwnership) Lower.Error!void {
    const self = borrow(writer);
    const target = &self.builder.nodes.expressions;

    if (forms) |extra| {
        const joined = view.join(source.*, extra.*);

        return appendRows(self, target, &joined, mode);
    }

    return appendRows(self, target, source, mode);
}

pub fn astExpressionCount(writer: *anyopaque) u32 {
    return @intCast(borrow(writer).builder.nodes.expressions.tags.items.len);
}

pub fn auxiliaryDeclarationCount(writer: *anyopaque) u64 {
    return borrow(writer).task_declarations.count();
}

pub fn appendAuxiliaryRow(writer: *anyopaque, source: *const Ast.ConstantRows) Lower.Error![]const u8 {
    const self = borrow(writer);
    const values = try self.task_declarations.appendConstants(self.allocator, source, false);

    return values[0];
}

pub fn replaceAuxiliaryRow(writer: *anyopaque, slot: u64, source: *const Ast.ConstantRows) Lower.Error!void {
    const self = borrow(writer);

    return self.task_declarations.replaceConstant(self.allocator, @intCast(slot), source);
}

pub fn joinAstDeclarationRows(writer: *anyopaque, starts: []const u32, counts: []const u32) Lower.Error!u64 {
    const self = borrow(writer);
    const result = try blocks.joinDeclarations(self.allocator, self.builder.nodes, starts, counts);
    const packed_span: packed struct(u64) { count: u32, start: u32 } = .{ .count = result.len, .start = result.start };

    return @bitCast(packed_span);
}

pub fn astFieldCount(writer: *anyopaque) u32 {
    return @intCast(borrow(writer).builder.nodes.field_columns.count());
}

pub fn astDeclarationCount(writer: *anyopaque) u32 {
    return @intCast(borrow(writer).builder.nodes.declaration_rows.tags.items.len);
}

pub fn astColumnCount(writer: *anyopaque, column: Ast.AstColumn) u64 {
    const nodes = borrow(writer).builder.nodes;

    return switch (column) {
        .Identifiers => nodes.expressions.payloads.identifier.values.items.len,
        .SelectionArms => nodes.arm_columns.count(),
    };
}

pub fn replaceAstIdentifier(writer: *anyopaque, index: u64, name: []const u8) void {
    borrow(writer).builder.nodes.expressions.payloads.identifier.values.items[@intCast(index)] = name;
}

pub fn appendExtendedExpressions(writer: *anyopaque, source: *const Ast.ExpressionRows, forms: ?*const Ast.ExpressionForms, extensions: *const Ast.ExpressionExtensions) Lower.Error!void {
    const self = borrow(writer);
    const rows = view.join(source.*, extensions.*);

    if (forms) |values| {
        const joined = view.join(rows, values.*);

        return appendRows(self, &self.builder.nodes.expressions, &joined, .BorrowingText);
    }

    return appendRows(self, &self.builder.nodes.expressions, &rows, .BorrowingText);
}

pub fn appendLayoutExpressions(writer: *anyopaque, source: *const Ast.ExpressionRows, layouts: *const Ast.ExpressionLayouts) Lower.Error!void {
    const self = borrow(writer);
    const joined = view.join(source.*, layouts.*);

    return appendRows(self, &self.builder.nodes.expressions, &joined, .Owned);
}

pub fn appendAstFields(writer: *anyopaque, source: *const Ast.FieldRows) Lower.Error!void {
    const self = borrow(writer);

    _ = fields.appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, source) catch |err| return failure(err);
}

pub fn appendOwnedAstFields(writer: *anyopaque, source: *const Ast.FieldRows) Lower.Error!void {
    const self = borrow(writer);

    fields.append(self.allocator, &self.builder.nodes.field_columns, source) catch |err| return failure(err);
}

pub fn astStatementCount(writer: *anyopaque) u32 {
    return @intCast(borrow(writer).builder.nodes.statements.tags.items.len);
}

pub fn tailAstStatementRows(writer: *anyopaque, starts: []const u32, counts: []const u32) Lower.Error!u32 {
    const self = borrow(writer);
    const block = try blocks.tail(self.allocator, self.builder.nodes, starts, counts);

    return block.start;
}

pub fn tailAstPackedStatements(writer: *anyopaque, spans: []const u64) Lower.Error!u64 {
    const self = borrow(writer);

    return packSpan(try blocks.joinStatementSpans(self.allocator, self.builder.nodes, spans, true));
}

pub fn appendAstFunctions(writer: *anyopaque, source: *const Ast.FunctionRows) Lower.Error!void {
    const self = borrow(writer);
    const target = &self.builder.nodes.declaration_rows;
    const Tag = std.meta.Child(@TypeOf(target.tags.items));
    var buffer: [8]Tag = undefined;
    var scratch: std.heap.BufferFirstAllocator = .init(std.mem.sliceAsBytes(&buffer), self.workspace);
    const allocator = scratch.allocator();
    const tags = try allocator.alloc(Tag, source.offsets.len);

    defer allocator.free(tags);
    @memset(tags, .Function);

    const joined = view.join(source.*, .{ .tags = @as([]const Tag, tags) });

    return appendRows(self, target, &joined, .BorrowingText);
}

pub fn appendStatementRows(writer: *anyopaque, source: *const Ast.StatementRows, variables: ?*const Ast.StatementVariables, mode: Ast.AstPayloadOwnership) Lower.Error!void {
    const self = borrow(writer);
    const target = &self.builder.nodes.statements;

    if (mode == .Selected) {
        if (variables) |extra| {
            const joined = view.join(source.*, extra.*);

            sparse.append(self.allocator, target, &joined) catch |err| return failure(err);
        } else {
            sparse.append(self.allocator, target, source) catch |err| return failure(err);
        }

        return;
    }

    if (variables) |extra| {
        const joined = view.join(source.*, extra.*);

        return appendRows(self, target, &joined, mode);
    }

    return appendRows(self, target, source, mode);
}

fn appendRows(self: *Lower, target: anytype, source: anytype, mode: Ast.AstPayloadOwnership) Lower.Error!void {
    const result = switch (mode) {
        .Owned => dense.append(self.allocator, target, source),
        .BorrowingText => dense.appendBorrowingText(self.allocator, target, source),
        .Borrowed => dense.appendBorrowed(self.allocator, target, source),
        .Selected => unreachable,
    };

    return result catch |err| failure(err);
}

pub fn retainAstIds(writer: *anyopaque, ids: []const u32) Lower.Error![]const u32 {
    return borrow(writer).allocator.dupe(u32, ids);
}

pub fn appendAstLiteralRows(writer: *anyopaque, source: *const Ast.AstLiteralRows, arguments: []const []const u32) Lower.Error!void {
    const self = borrow(writer);
    const rows = view.join(source.*, .{ .builtin_arguments = arguments });

    return appendRows(self, &self.builder.nodes.expressions, &rows, .Borrowed);
}

pub fn appendAstObjectFields(writer: *anyopaque, source: *const Ast.AstObjectFields) Lower.Error!void {
    const self = borrow(writer);

    return fields.appendObject(self.allocator, &self.builder.nodes.field_columns, source);
}

const Span = packed struct(u64) { count: u32, start: u32 };

pub fn packSpan(block: node.Block) u64 {
    return @bitCast(Span{ .start = block.start, .count = block.len });
}

pub fn unpackSpan(span: u64) node.Block {
    const decoded: Span = @bitCast(span);

    return .{ .start = decoded.start, .len = decoded.count };
}

pub fn appendAstCleanupRows(
    writer: *anyopaque,
    tags: []const Ast.StatementsKind,
    offsets: []const u32,
    variables: ?*const Ast.StatementVariables,
    discards: []const u32,
    defer_starts: []const u32,
    defer_counts: []const u32,
) Lower.Error!u64 {
    const self = borrow(writer);

    const source = .{
        .tags = tags,
        .offsets = offsets,
        .discard_error = discards,
        .defer_scope_start = defer_starts,
        .defer_scope_len = defer_counts,
    };
    const block = if (variables) |values| written: {
        const joined = view.join(source, values.*);

        break :written try self.builder.publishStatements(&joined);
    } else try self.builder.publishStatements(&source);

    return packSpan(block);
}

pub fn appendStatementSequence(writer: *anyopaque, handle: *anyopaque, source: *const Ast.StatementRows, variables: *const Ast.StatementVariables, mode: Ast.AstSequenceMode) Lower.Error!void {
    const allocator = borrow(writer).allocator;
    const target: *Sequence = @ptrCast(@alignCast(handle));
    const joined = view.join(source.*, variables.*);

    const result = switch (mode) {
        .Owned => statements.append(allocator, target, &joined),
        .BorrowingText => statements.appendBorrowingText(allocator, target, &joined),
        .SelectedOwned => statements.appendSelected(allocator, target, &joined),
        .SelectedBorrowingText => statements.appendSelectedBorrowingText(allocator, target, &joined),
    };

    result catch |err| return failure(err);
}

pub fn hoistStatementRows(writer: *anyopaque, source: *const Ast.StatementRows, variables: *const Ast.StatementVariables) Lower.Error!void {
    const joined = view.join(source.*, variables.*);

    return borrow(writer).hoistReferences(&joined);
}

pub fn appendAuxiliaryFunction(writer: *anyopaque, functions: *const Ast.FunctionRows, parameters: *const Ast.FieldRows) Lower.Error!void {
    const self = borrow(writer);
    const Tag = std.meta.Child(@TypeOf(self.builder.nodes.declaration_rows.tags.items));
    const imported = fields.appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, parameters) catch |err| return failure(err);
    const rows = view.join(functions.*, .{ .tags = @as([]const Tag, &.{.Function}) });

    try self.task_declarations.appendFunction(self.allocator, &rows, imported.start);
}

pub fn appendAstBindingRows(writer: *anyopaque, handle: *anyopaque, source: *const Ast.BindingRows) Lower.Error!void {
    return appendSequenceRows(writer, handle, source);
}

pub fn publishAstBindingRows(writer: *anyopaque, source: *const Ast.BindingRows) Lower.Error!u64 {
    const self = borrow(writer);
    const target = &self.builder.nodes.statements;
    const start: u32 = @intCast(target.tags.items.len);

    try appendRows(self, target, source, .BorrowingText);

    return packSpan(.{ .start = start, .len = @intCast(source.tags.len) });
}

pub fn publishAstBasicStatements(writer: *anyopaque, source: *const Ast.BasicStatementRows) Lower.Error!u64 {
    return packSpan(try borrow(writer).builder.publishStatements(source));
}

fn appendSequenceRows(writer: *anyopaque, handle: *anyopaque, source: anytype) Lower.Error!void {
    const target: *Sequence = @ptrCast(@alignCast(handle));

    statements.appendBorrowingText(borrow(writer).allocator, target, source) catch |err| return failure(err);
}

pub fn extendStatementSequence(handle: *anyopaque, suffix: *anyopaque) Lower.Error!void {
    const target: *Sequence = @ptrCast(@alignCast(handle));
    const source: *const Sequence = @ptrCast(@alignCast(suffix));

    return target.extend(source);
}

pub fn statementSequenceBlock(writer: *anyopaque, handle: *anyopaque) Lower.Error!u64 {
    const target: *Sequence = @ptrCast(@alignCast(handle));
    const block = try target.block(borrow(writer).allocator);

    return packSpan(block);
}

pub fn appendAstSequenceSpan(handle: *anyopaque, span: u64) Lower.Error!void {
    const target: *Sequence = @ptrCast(@alignCast(handle));

    return target.append(unpackSpan(span));
}

pub fn finishAstSequence(writer: *anyopaque, handle: *anyopaque) Lower.Error!u64 {
    const target: *Sequence = @ptrCast(@alignCast(handle));

    return packSpan(try target.finish(borrow(writer).allocator));
}

pub fn takeAstSequence(writer: *anyopaque, handle: *anyopaque, at_tail: bool) Lower.Error!u64 {
    const target: *Sequence = @ptrCast(@alignCast(handle));
    const allocator = borrow(writer).allocator;
    const span = if (at_tail) try target.finish(allocator) else try target.block(allocator);

    target.clearRetainingCapacity();

    return packSpan(span);
}

pub fn joinAstStatementRows(writer: *anyopaque, starts: []const u32, counts: []const u32) Lower.Error!u32 {
    const self = borrow(writer);
    const block = try blocks.join(self.allocator, self.builder.nodes, starts, counts);

    return block.start;
}

pub fn executeSpan(self: *Lower, comptime fragment: type, input: fragment.Input) Lower.Error!node.Block {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const encoded = fragment.executeIn(memory.allocator(), input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return unpackSpan(encoded);
}

pub fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.InvalidAst => @panic("invalid AST fragment publication"),
        else => unreachable,
    };
}
