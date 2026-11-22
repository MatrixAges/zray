const std = @import("std");
const zx = @import("zx");
const view = @import("view.zig");
const rows = @import("import_rows.zig");
const payloads = @import("import_payloads.zig");
const fields = @import("import_fields.zig");
const generated = @import("genz_options").generated_analysis;
const Storage = @import("storage.zig");
pub const Error = rows.Error;
const Mode = enum { owned, text, borrowed };

pub fn append(allocator: std.mem.Allocator, target: *Storage, comptime Module: type, source: anytype) Error!void {
    return appendModule(allocator, target, Module, source, .owned);
}

/// Text must outlive the target; non-text payloads receive owned storage.
pub fn appendBorrowingText(allocator: std.mem.Allocator, target: *Storage, comptime Module: type, source: anytype) Error!void {
    return appendModule(allocator, target, Module, source, .text);
}

/// All payloads must outlive the target; column descriptors receive owned storage.
pub fn appendBorrowed(allocator: std.mem.Allocator, target: *Storage, comptime Module: type, source: anytype) Error!void {
    return appendModule(allocator, target, Module, source, .borrowed);
}

fn appendModule(allocator: std.mem.Allocator, target: *Storage, comptime Module: type, source: anytype, comptime mode: Mode) Error!void {
    const expressions = expressionColumns(Module, source);
    const statements = statementColumns(Module, source);
    const declarations = declarationColumns(Module, source);

    if (generated) return appendSource(allocator, target, expressions, statements, declarations, source, @hasField(Module, "fields"), mode);

    try appendRows(allocator, &target.expressions, &expressions, mode);
    if (@TypeOf(statements) != void) try appendRows(allocator, &target.statements, &statements, mode);

    if (@hasField(Module, "fields")) {
        if (comptime mode != .owned) {
            _ = try fields.appendBorrowingText(allocator, &target.field_columns, source.fields);
        } else try fields.append(allocator, &target.field_columns, source.fields);
    }

    if (@TypeOf(declarations) != void) try appendRows(allocator, &target.declaration_rows, &declarations, mode);
}

fn appendSource(allocator: std.mem.Allocator, target: *Storage, expressions: anytype, statements: anytype, declarations: anytype, source: anytype, comptime has_fields: bool, comptime mode: Mode) Error!void {
    const entry = @import("generated_node_append_module");
    const Input = std.meta.Child(entry.Input);
    const Rows = std.meta.Child(@FieldType(Input, "expressions"));
    const Field = std.meta.Child(@typeInfo(@FieldType(Input, "fields")).optional.child);
    const copy = mode != .borrowed;
    const borrow_text = mode != .owned;
    var expression_binding: payloads.Binding(@TypeOf(&target.expressions), @TypeOf(expressions)) = .{};
    var statement_binding: if (@TypeOf(statements) == void) void else payloads.Binding(@TypeOf(&target.statements), @TypeOf(statements)) = if (@TypeOf(statements) == void) {} else .{};
    var declaration_binding: if (@TypeOf(declarations) == void) void else payloads.Binding(@TypeOf(&target.declaration_rows), @TypeOf(declarations)) = if (@TypeOf(declarations) == void) {} else .{};
    var field_binding: payloads.Plain = .{};
    const field_columns = if (has_fields) fields.bindColumns(&target.field_columns, source.fields, borrow_text) else {};
    const expression_view = expression_binding.bind(Rows, &allocator, &target.expressions, &expressions, copy, borrow_text);

    const statement_view = if (@TypeOf(statements) != void)
        statement_binding.bind(Rows, &allocator, &target.statements, &statements, copy, borrow_text)

    else {};

    const declaration_view = if (@TypeOf(declarations) != void)
        declaration_binding.bind(Rows, &allocator, &target.declaration_rows, &declarations, copy, borrow_text)

    else {};

    const field_view = if (has_fields)
        field_binding.bind(Field, &allocator, &field_columns, source.fields.name.len, target.field_columns.count(), borrow_text)

    else {};

    const input: Input = .{
        .expressions = &expression_view,
        .statements = if (@TypeOf(statements) != void) &statement_view else null,
        .fields = if (has_fields) &field_view else null,
        .declarations = if (@TypeOf(declarations) != void) &declaration_view else null,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| return payloads.failure(err);

    return switch (result) {
        .Valid => {},
        .Invalid => error.InvalidAst,
        .Exhausted => error.OutOfMemory,
    };
}

fn expressionColumns(comptime Module: type, source: anytype) ExpressionView(Module) {
    if (@hasField(Module, "context")) {
        const Context = Descriptor(@FieldType(Module, "context"));
        const context = source.context;
        const expressions = zx.columns.view(Descriptor(@FieldType(Context, "expressions")), context.expressions);
        const forms = zx.columns.view(Descriptor(@FieldType(Context, "forms")), context.forms);

        return if (@hasField(Module, "extra")) view.join(view.join(expressions, forms), zx.columns.view(Descriptor(@FieldType(Module, "extra")), source.extra)) else view.join(expressions, forms);
    }

    return zx.columns.view(Descriptor(@FieldType(Module, "expressions")), source.expressions);
}

fn statementColumns(comptime Module: type, source: anytype) StatementView(Module) {
    if (!@hasField(Module, "statements")) return;

    const statements = zx.columns.view(Descriptor(@FieldType(Module, "statements")), source.statements);
    const commands = if (@hasField(Module, "variables")) view.join(statements, zx.columns.view(Descriptor(@FieldType(Module, "variables")), source.variables)) else statements;

    if (@hasField(Module, "statement_forms") or @hasField(Module, "loops")) {
        const name = if (@hasField(Module, "statement_forms")) "statement_forms" else "loops";
        const extra = zx.columns.view(Descriptor(@FieldType(Module, name)), @field(source, name));

        return view.join(commands, extra);
    }

    return commands;
}

fn declarationColumns(comptime Module: type, source: anytype) DeclarationView(Module) {
    if (!@hasField(Module, "declarations") and !@hasField(Module, "functions")) return;

    const name = if (@hasField(Module, "declarations")) "declarations" else "functions";

    return zx.columns.view(Descriptor(@FieldType(Module, name)), @field(source, name));
}

fn ExpressionView(comptime Module: type) type {
    if (!@hasField(Module, "context")) return Descriptor(@FieldType(Module, "expressions"));

    const Context = Descriptor(@FieldType(Module, "context"));
    const Expressions = Descriptor(@FieldType(Context, "expressions"));
    const Forms = Descriptor(@FieldType(Context, "forms"));
    const Columns = view.Joined(Expressions, Forms);

    return if (@hasField(Module, "extra")) view.Joined(Columns, Descriptor(@FieldType(Module, "extra"))) else Columns;
}

fn StatementView(comptime Module: type) type {
    if (!@hasField(Module, "statements")) return void;

    const Statements = Descriptor(@FieldType(Module, "statements"));
    const Commands = if (@hasField(Module, "variables")) view.Joined(Statements, Descriptor(@FieldType(Module, "variables"))) else Statements;

    if (@hasField(Module, "statement_forms") or @hasField(Module, "loops")) {
        const name = if (@hasField(Module, "statement_forms")) "statement_forms" else "loops";

        return view.Joined(Commands, Descriptor(@FieldType(Module, name)));
    }

    return Commands;
}

fn DeclarationView(comptime Module: type) type {
    if (@hasField(Module, "declarations")) return Descriptor(@FieldType(Module, "declarations"));
    if (@hasField(Module, "functions")) return Descriptor(@FieldType(Module, "functions"));

    return void;
}

fn Descriptor(comptime Value: type) type {
    if (@typeInfo(Value) == .pointer) return std.meta.Child(Value);
    if (@hasField(Value, "zx_origin")) return std.meta.Child(std.meta.Child(@FieldType(Value, "zx_origin")));

    return Value;
}

fn appendRows(allocator: std.mem.Allocator, target: anytype, source: anytype, comptime mode: Mode) Error!void {
    return switch (mode) {
        .owned => rows.append(allocator, target, source),
        .text => rows.appendBorrowingText(allocator, target, source),
        .borrowed => rows.appendBorrowed(allocator, target, source),
    };
}
