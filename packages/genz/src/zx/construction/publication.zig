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

pub fn readAstOrigin(writer: *const anyopaque, buffer: *const anyopaque) *const Ast.AstOrigin {
    const self = borrow(writer);
    const target: *OriginBuffer = @ptrCast(@alignCast(@constCast(buffer)));

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

pub fn appendExpressionRows(writer: *const anyopaque, source: *const Ast.ExpressionRows, forms: ?*const Ast.ExpressionForms, mode: Ast.AstPayloadOwnership) Lower.Error!void {
    const self = borrow(writer);
    const target = &self.builder.nodes.expressions;

    if (forms) |extra| {
        const joined = view.join(source.*, extra.*);

        return appendRows(self, target, &joined, mode);
    }

    return appendRows(self, target, source, mode);
}

pub fn appendStatementRows(writer: *const anyopaque, source: *const Ast.StatementRows, variables: ?*const Ast.StatementVariables, mode: Ast.AstPayloadOwnership) Lower.Error!void {
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

const Span = packed struct(u64) { count: u32, start: u32 };

pub fn packSpan(block: node.Block) u64 {
    return @bitCast(Span{ .start = block.start, .count = block.len });
}

pub fn appendStatementSequence(writer: *const anyopaque, handle: *const anyopaque, source: *const Ast.StatementRows, variables: *const Ast.StatementVariables) Lower.Error!void {
    const target: *Sequence = @ptrCast(@alignCast(@constCast(handle)));
    const joined = view.join(source.*, variables.*);

    statements.appendBorrowingText(borrow(writer).allocator, target, &joined) catch |err| return failure(err);
}

pub fn extendStatementSequence(handle: *const anyopaque, suffix: *const anyopaque) Lower.Error!void {
    const target: *Sequence = @ptrCast(@alignCast(@constCast(handle)));
    const source: *const Sequence = @ptrCast(@alignCast(suffix));

    return target.extend(source);
}

pub fn statementSequenceBlock(writer: *const anyopaque, handle: *const anyopaque) Lower.Error!u64 {
    const target: *Sequence = @ptrCast(@alignCast(@constCast(handle)));
    const block = try target.block(borrow(writer).allocator);

    return packSpan(block);
}

pub fn joinAstSpans(writer: *const anyopaque, first: u64, second: u64) Lower.Error!u64 {
    const self = borrow(writer);
    const left: Span = @bitCast(first);
    const right: Span = @bitCast(second);
    const block = try blocks.join(self.allocator, self.builder.nodes, &.{ left.start, right.start }, &.{ left.count, right.count });

    return packSpan(block);
}

pub fn appendAstSpan(writer: *const anyopaque, span: u64) Lower.Error!void {
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
    fn borrow(target: *const anyopaque) *const Frame {
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

    const frame: Frame = .{
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

pub fn appendFragmentExpressions(handle: *const anyopaque, borrow_text: bool) Lower.Error!void {
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

pub fn appendFragmentLayoutExpressions(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const source = view.join(frame.expressions.*, frame.layouts.?.*);
    const target = &frame.lower.builder.nodes.expressions;

    dense.append(frame.lower.allocator, target, &source) catch |err| return failure(err);
}

pub fn appendFragmentStatements(handle: *const anyopaque, mode: Api.FragmentStatements) Lower.Error!void {
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

pub fn appendFragmentBody(handle: *const anyopaque, mode: Api.FragmentBody) Lower.Error!void {
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

pub fn appendFragmentStorage(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const source = view.join(frame.roots.?.*, frame.vars.?.*);

    return frame.lower.hoistReferences(&source);
}

pub fn appendFragmentFields(handle: *const anyopaque, own_text: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const target = &frame.lower.builder.nodes.field_columns;
    const allocator = frame.lower.allocator;

    if (own_text) {
        fields.append(allocator, target, frame.fields.?) catch |err| return failure(err);
    } else {
        _ = fields.appendBorrowingText(allocator, target, frame.fields.?) catch |err| return failure(err);
    }
}

pub fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.InvalidAst => @panic("invalid AST fragment publication"),
        else => unreachable,
    };
}
