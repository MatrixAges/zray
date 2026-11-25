const std = @import("std");
const columns = @import("zx").columns;
const Lower = @import("../lower.zig");
const blocks = @import("../../node/blocks.zig");
const node = @import("../../node.zig");
const Sequence = blocks.Sequence;
const view = @import("../../node/view.zig");
const dense = @import("../../node/import_rows.zig");
const sparse = @import("../../node/import_selected.zig");
const statements = @import("../../node/import_statements.zig");
const fields = @import("../../node/import_fields.zig");
const entry = @import("generated_publish_ast_fragment");
const Input = std.meta.Child(entry.Input);
const Kind = @FieldType(Input, "kind");
const Api = @import("../expressions/evaluate.zig").Api;
const Ast = @import("execution_abi").layouts.@"zig:ast_rows";
const borrow = @import("../expressions/evaluate.zig").borrow;
const Update = std.meta.Child(@import("generated_list_update").Output);
const Collection = std.meta.Child(@import("generated_emit_collection_rows").Output);
const Context = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Collection, "state")), "context"));
const IterationTypes = std.meta.Child(@import("generated_iteration_types_emit").Output);
const Expressions = @FieldType(Update, "expressions");
const Forms = @FieldType(Update, "forms");
const Rows = @FieldType(Update, "statements");

pub const OriginBuffer = struct {
    origin: Ast.AstOrigin = undefined,
    capture: Ast.AstCapture = undefined,
};

pub const Scratch = struct {
    arena: *std.heap.ArenaAllocator,
    memory: *std.heap.BufferFirstAllocator,
};

pub fn releaseAstScratch(handle: *const anyopaque) void {
    const scratch: *const Scratch = @ptrCast(@alignCast(handle));

    scratch.memory.fixed_buffer_allocator.reset();

    _ = scratch.arena.reset(.free_all);
}

pub fn readAstOrigin(writer: *anyopaque, buffer: *anyopaque) *const Ast.AstOrigin {
    const self = borrow(writer);
    const target: *OriginBuffer = @ptrCast(@alignCast(buffer));

    if (self.capture) |capture| {
        target.capture = .{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) };
    }

    target.origin = .{
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
        .capture = if (self.capture == null) null else &target.capture,
    };

    return &target.origin;
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

pub fn appendAstExpressionHeaders(writer: *anyopaque, tags: []const Ast.ExpressionsKind, offsets: []const u32) Lower.Error!void {
    const self = borrow(writer);
    const source = .{ .tags = tags, .offsets = offsets };

    return appendRows(self, &self.builder.nodes.expressions, &source, .BorrowingText);
}

pub fn appendAstNamespaceRows(writer: *anyopaque, source: *const Ast.NamespaceRows) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.expressions, source, .BorrowingText);
}

pub fn appendAstProjectionRows(writer: *anyopaque, source: *const Ast.ProjectionRows) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.expressions, source, .Borrowed);
}

pub fn appendAuxiliaryRow(writer: *anyopaque, source: *const Ast.ConstantRows) Lower.Error![]const u8 {
    const self = borrow(writer);
    const values = try self.task_declarations.appendConstants(self.allocator, source, false);

    return values[0];
}

pub fn appendAstDeclaredConstants(writer: *anyopaque, handle: *anyopaque, source: *const Ast.ConstantRows) Lower.Error!void {
    const self = borrow(writer);
    const target: *@import("../../node/declarations.zig").Sequence = @ptrCast(@alignCast(handle));
    const Tag = std.meta.Child(@TypeOf(self.builder.nodes.declaration_rows.tags.items));
    var buffer: [8]Tag = undefined;
    var scratch: std.heap.BufferFirstAllocator = .init(std.mem.sliceAsBytes(&buffer), self.workspace);
    const allocator = scratch.allocator();
    const tags = try allocator.alloc(Tag, source.offsets.len);

    defer allocator.free(tags);
    @memset(tags, .Constant);

    const rows = view.join(source.*, .{ .tags = @as([]const Tag, tags) });

    target.appendColumns(self.allocator, &rows, true) catch |err| return failure(err);
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

pub fn astIdentifierCount(writer: *anyopaque) u64 {
    return borrow(writer).builder.nodes.expressions.payloads.identifier.values.items.len;
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
    };

    return result catch |err| failure(err);
}

pub fn appendAstBlockRows(writer: *anyopaque, source: *const Ast.AstBlockRows, conditionals: ?*const Ast.AstConditionalRows) Lower.Error!void {
    const self = borrow(writer);
    const target = &self.builder.nodes.expressions;

    if (conditionals) |extra| {
        const joined = view.join(source.*, extra.*);

        return appendRows(self, target, &joined, .Borrowed);
    }

    return appendRows(self, target, source, .Borrowed);
}

pub fn appendAstIdentifierRows(writer: *anyopaque, source: *const Ast.AstIdentifierRows) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.expressions, source, .Borrowed);
}

pub fn retainAstIds(writer: *anyopaque, ids: []const u32) Lower.Error![]const u32 {
    return borrow(writer).allocator.dupe(u32, ids);
}

pub fn storeAstIdPair(writer: *anyopaque, first: u32, second: u32) Lower.Error![]const u32 {
    const ids = try borrow(writer).allocator.create([2]u32);

    ids.* = .{ first, second };

    return ids;
}

pub fn appendAstLiteralRows(writer: *anyopaque, source: *const Ast.AstLiteralRows, arguments: []const []const u32) Lower.Error!void {
    return appendValueRows(writer, source, .{ .builtin_arguments = arguments });
}

pub fn appendAstAccessRows(writer: *anyopaque, source: *const Ast.AstAccessRows, arguments: []const []const u32) Lower.Error!void {
    return appendValueRows(writer, source, .{ .builtin_arguments = arguments });
}

pub fn appendAstArrayRows(writer: *anyopaque, source: *const Ast.AstArrayRows, arguments: []const []const u32) Lower.Error!void {
    return appendValueRows(writer, source, .{ .builtin_arguments = arguments });
}

pub fn appendAstAllocationCallRows(writer: *anyopaque, source: *const Ast.AstAllocationCallRows, arguments: []const []const u32) Lower.Error!void {
    return appendValueRows(writer, source, .{ .call_arguments = arguments });
}

fn appendValueRows(writer: *anyopaque, source: anytype, arguments: anytype) Lower.Error!void {
    const self = borrow(writer);
    const rows = view.join(source.*, arguments);

    return appendRows(self, &self.builder.nodes.expressions, &rows, .Borrowed);
}

pub fn appendAstOperandRows(writer: *anyopaque, source: *const Ast.AstOperandRows) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.expressions, source, .Borrowed);
}

pub fn appendAstObjectRows(writer: *anyopaque, source: *const Ast.AstObjectRows) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.expressions, source, .Borrowed);
}

pub fn appendAstObjectFields(writer: *anyopaque, source: *const Ast.AstObjectFields) Lower.Error!void {
    const self = borrow(writer);

    return fields.appendObject(self.allocator, &self.builder.nodes.field_columns, source);
}

pub fn appendAstFieldAddresses(writer: *anyopaque, source: *const Ast.AstFieldAddressRows) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.expressions, source, .Borrowed);
}

pub fn appendAstLeafStatements(writer: *anyopaque, source: *const Ast.AstLeafStatements) Lower.Error!void {
    const self = borrow(writer);

    return appendRows(self, &self.builder.nodes.statements, source, .Borrowed);
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

pub fn publishAstScopedRows(writer: *anyopaque, source: *const Ast.StatementRows, variables: *const Ast.StatementVariables, starts: []const u32, counts: []const u32) Lower.Error!u64 {
    const self = borrow(writer);
    const joined = view.join(view.join(source.*, variables.*), .{ .scope_start = starts, .scope_len = counts });

    return packSpan(try self.builder.publishStatements(&joined));
}

pub fn appendStatementSequence(writer: *anyopaque, handle: *anyopaque, source: *const Ast.StatementRows, variables: *const Ast.StatementVariables) Lower.Error!void {
    const joined = view.join(source.*, variables.*);

    return appendSequenceRows(writer, handle, &joined);
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

pub fn joinAstSpans(writer: *anyopaque, first: u64, second: u64) Lower.Error!u64 {
    const self = borrow(writer);
    const left: Span = @bitCast(first);
    const right: Span = @bitCast(second);
    const block = try blocks.join(self.allocator, self.builder.nodes, &.{ left.start, right.start }, &.{ left.count, right.count });

    return packSpan(block);
}

pub fn joinAstStatementRows(writer: *anyopaque, starts: []const u32, counts: []const u32) Lower.Error!u32 {
    const self = borrow(writer);
    const block = try blocks.join(self.allocator, self.builder.nodes, starts, counts);

    return block.start;
}

pub fn appendAstSpan(writer: *anyopaque, span: u64) Lower.Error!void {
    const self = borrow(writer);
    const part: Span = @bitCast(span);

    return blocks.appendAtTail(self.allocator, self.builder.nodes, .{ .start = part.start, .len = part.count });
}

pub const Targets = struct {
    body: ?*Sequence = null,
    binding: ?*Sequence = null,
};

pub const Frame = struct {
    lower: *Lower,
    targets: Targets = .{},
    expressions: Expressions,
    forms: ?Forms = null,
    layouts: ?@FieldType(IterationTypes, "layouts") = null,
    statements: ?Rows = null,
    vars: ?@FieldType(Context, "variables") = null,
    subset: ?@FieldType(Update, "body") = null,
    roots: ?Rows = null,
    converted_body: ?Rows = null,
    converted_binding: ?Rows = null,
    fields: ?@FieldType(Update, "fields") = null,
    fn borrow(target: *anyopaque) *const Frame {
        return @ptrCast(@alignCast(target));
    }
};

pub fn write(self: *Lower, targets: Targets, output: anytype, comptime kind: Kind) Lower.Error!void {
    const data = switch (kind) {
        .Growth => &output.result,
        .Collection => output.state.context,
        else => output,
    };

    const expressions = if (kind == .Growth) columns.view(std.meta.Child(Expressions), data.expressions) else undefined;
    const forms = if (kind == .Growth) columns.view(std.meta.Child(Forms), data.forms) else undefined;

    var frame: Frame = .{
        .lower = self,
        .targets = targets,
        .expressions = if (kind == .Growth) &expressions else columns.pointer(Expressions, data.expressions),
        .forms = if (kind == .Growth) &forms else columns.pointer(Forms, data.forms),
        .statements = if (kind == .List or kind == .Origin) null else columns.pointer(Rows, data.statements),
        .vars = switch (kind) {
            .Collection, .Construction, .Conversion => columns.pointer(@FieldType(Context, "variables"), data.variables),
            else => null,
        },
        .subset = switch (kind) {
            .Collection => columns.pointer(@FieldType(Update, "body"), output.state.body),
            .Update => output.body,
            else => null,
        },
        .roots = switch (kind) {
            .Growth => columns.pointer(Rows, data.body),
            .Guard => columns.pointer(Rows, output.roots),
            .Construction, .Conversion => columns.pointer(Rows, data.storage),
            else => null,
        },
        .converted_body = if (kind == .Conversion) columns.pointer(Rows, data.body) else null,
        .converted_binding = if (kind == .Conversion) columns.pointer(Rows, data.borrow_storage) else null,
        .fields = switch (kind) {
            .Growth => if (output.fields) |source| columns.pointer(@FieldType(Update, "fields"), source) else null,
            .Collection, .Update, .List, .Conversion => columns.pointer(@FieldType(Update, "fields"), output.fields),
            else => null,
        },
    };

    const input: Input = .{
        .target = @ptrCast(&frame),
        .lower = @ptrCast(self),
        .kind = kind,
        .sequence = targets.body != null,
        .fields = frame.fields != null,
        .valid = if (kind == .Growth) data.valid else output.valid,
        .serial = switch (kind) {
            .Growth => data.serial,
            .Guard, .List, .Origin => 0,
            else => output.serial,
        },
        .uses_allocator = kind != .Guard and kind != .List and kind != .Origin and output.uses_allocator,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input);
}

pub fn appendFragmentExpressions(handle: *anyopaque, borrow_text: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const target = &frame.lower.builder.nodes.expressions;
    const allocator = frame.lower.allocator;
    const source = view.join(frame.expressions.*, frame.forms.?.*);

    if (borrow_text) {
        dense.appendBorrowingText(allocator, target, &source) catch |err| return failure(err);
    } else {
        dense.append(allocator, target, &source) catch |err| return failure(err);
    }
}

pub fn appendFragmentLayoutExpressions(handle: *anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const source = view.join(frame.expressions.*, frame.layouts.?.*);
    const target = &frame.lower.builder.nodes.expressions;

    dense.append(frame.lower.allocator, target, &source) catch |err| return failure(err);
}

pub fn appendFragmentStatements(handle: *anyopaque, mode: Api.FragmentStatements) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const target = &frame.lower.builder.nodes.statements;
    const allocator = frame.lower.allocator;

    switch (mode) {
        .Dense => dense.append(allocator, target, frame.statements.?) catch |err| return failure(err),
        .BorrowingText => dense.appendBorrowingText(allocator, target, frame.statements.?) catch |err| return failure(err),
        .Borrowed => dense.appendBorrowed(allocator, target, frame.statements.?) catch |err| return failure(err),
        .Sparse => sparse.append(allocator, target, frame.statements.?) catch |err| return failure(err),
        .SparseWithVariables => {
            const source = view.join(frame.statements.?.*, frame.vars.?.*);

            sparse.append(allocator, target, &source) catch |err| return failure(err);
        },
    }
}

pub fn appendFragmentBody(handle: *anyopaque, mode: Api.FragmentBody) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.lower.allocator;

    switch (mode) {
        .Direct => dense.append(allocator, &frame.lower.builder.nodes.statements, frame.roots.?) catch |err| return failure(err),
        .Roots => statements.append(allocator, frame.targets.body.?, frame.roots.?) catch |err| return failure(err),
        .RootsWithVariables => {
            const source = view.join(frame.roots.?.*, frame.vars.?.*);

            statements.append(allocator, frame.targets.body.?, &source) catch |err| return failure(err);
        },
        .BorrowedRoots => statements.appendBorrowingText(allocator, frame.targets.body.?, frame.roots.?) catch |err| return failure(err),
        .Selected, .SelectedWithVariables => {
            var roots = frame.statements.?.*;
            roots.tags = frame.subset.?.tags;
            roots.offsets = frame.subset.?.offsets;

            const target = frame.targets.body.?;

            if (mode == .SelectedWithVariables) {
                const source = view.join(roots, frame.vars.?.*);

                statements.appendSelected(allocator, target, &source) catch |err| return failure(err);
            } else {
                statements.appendSelected(allocator, target, &roots) catch |err| return failure(err);
            }
        },
        .ConvertedBinding, .ConvertedBody => {
            const binding = mode == .ConvertedBinding;
            const target = if (binding) frame.targets.binding.? else frame.targets.body.?;
            const part = if (binding) frame.converted_binding.? else frame.converted_body.?;
            const source = view.join(part.*, frame.vars.?.*);

            statements.appendSelected(allocator, target, &source) catch |err| return failure(err);
        },
    }
}

pub fn appendFragmentStorage(handle: *anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const source = view.join(frame.roots.?.*, frame.vars.?.*);

    return frame.lower.hoistReferences(&source);
}

pub fn appendFragmentFields(handle: *anyopaque, own_text: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const target = &frame.lower.builder.nodes.field_columns;
    const allocator = frame.lower.allocator;

    if (own_text) {
        fields.append(allocator, target, frame.fields.?) catch |err| return failure(err);
    } else {
        _ = fields.appendBorrowingText(allocator, target, frame.fields.?) catch |err| return failure(err);
    }
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
