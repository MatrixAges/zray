const std = @import("std");
const zx = @import("zx");
const view = @import("view.zig");
const rows = @import("import_rows.zig");
const payloads = @import("import_payloads.zig");
const fields = @import("import_fields.zig");
const generated = @import("genz_options").generated_analysis;
const Storage = @import("storage.zig");
pub const Error = rows.Error;
pub const Mode = enum { owned, text, borrowed };

pub const Modes = struct {
    expressions: Mode,
    statements: Mode = .owned,
    declarations: Mode = .owned,
    borrow_field_text: bool = false,
};

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

    if (generated) return appendColumns(allocator, target, .{
        .expressions = expressions,
        .statements = statements,
        .declarations = declarations,
        .fields = if (@hasField(Module, "fields")) source.fields else {},
    }, .{
        .expressions = mode,
        .statements = mode,
        .declarations = mode,
        .borrow_field_text = mode != .owned,
    });

    try appendRows(allocator, &target.expressions, &expressions, mode);

    if (@TypeOf(statements) != void) try appendRows(allocator, &target.statements, &statements, mode);

    if (@hasField(Module, "fields")) {
        if (comptime mode != .owned) {
            _ = try fields.appendBorrowingText(allocator, &target.field_columns, source.fields);
        } else try fields.append(allocator, &target.field_columns, source.fields);
    }

    if (@TypeOf(declarations) != void) try appendRows(allocator, &target.declaration_rows, &declarations, mode);
}

/// Publishes already bound column views, with each payload borrowing or owning its data.
pub fn appendColumns(allocator: std.mem.Allocator, target: *Storage, source: anytype, comptime modes: Modes) Error!void {
    const entry = @import("generated_node_append_module");
    const Input = std.meta.Child(entry.Input);
    const Rows = std.meta.Child(@FieldType(Input, "expressions"));
    const Field = std.meta.Child(@typeInfo(@FieldType(Input, "fields")).optional.child);
    const expressions = source.expressions;
    const statements = source.statements;
    const declarations = source.declarations;
    const has_fields = @TypeOf(source.fields) != void;
    var expression_binding: payloads.Binding(@TypeOf(&target.expressions), @TypeOf(expressions), .dense) = .{};
    var statement_binding: if (@TypeOf(statements) == void) void else payloads.Binding(@TypeOf(&target.statements), @TypeOf(statements), .dense) = if (@TypeOf(statements) == void) {} else .{};
    var declaration_binding: if (@TypeOf(declarations) == void) void else payloads.Binding(@TypeOf(&target.declaration_rows), @TypeOf(declarations), .dense) = if (@TypeOf(declarations) == void) {} else .{};
    var field_binding: payloads.Plain = .{};
    const field_columns = if (has_fields) fields.bindColumns(&target.field_columns, source.fields, modes.borrow_field_text) else {};
    var field_lengths: [if (has_fields) field_columns.len else 0]?u64 = undefined;
    const expression_view = expression_binding.bind(Rows, &allocator, &target.expressions, &expressions, modes.expressions != .borrowed, modes.expressions != .owned);

    const statement_view = if (@TypeOf(statements) != void)
        statement_binding.bind(Rows, &allocator, &target.statements, &statements, modes.statements != .borrowed, modes.statements != .owned)

    else {};

    const declaration_view = if (@TypeOf(declarations) != void)
        declaration_binding.bind(Rows, &allocator, &target.declaration_rows, &declarations, modes.declarations != .borrowed, modes.declarations != .owned)

    else {};

    const field_view = if (has_fields)
        field_binding.bind(Field, &allocator, &field_columns, &field_lengths, source.fields.name.len, target.field_columns.count(), modes.borrow_field_text)

    else {};

    const input: Input = .{
        .expressions = &expression_view,
        .statements = if (@TypeOf(statements) != void) &statement_view else null,
        .fields = if (has_fields) &field_view else null,
        .declarations = if (@TypeOf(declarations) != void) &declaration_view else null,
    };

    var scratch_buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const result = zx.columns.invoke(entry.executeValue, fallback.allocator(), &input) catch |err| {
        if (@TypeOf(declarations) != void) declaration_binding.rollback(&allocator);
        if (has_fields) field_binding.rollback(&allocator);
        if (@TypeOf(statements) != void) statement_binding.rollback(&allocator);

        expression_binding.rollback(&allocator);

        return payloads.failure(err);
    };

    payloads.appendHeaders(&target.expressions, expressions.tags, result.expressions);

    if (@TypeOf(statements) != void) {
        if (result.statements) |plan| payloads.appendHeaders(&target.statements, statements.tags, plan);
    }

    if (@TypeOf(declarations) != void) {
        if (result.declarations) |plan| payloads.appendHeaders(&target.declaration_rows, declarations.tags, plan);
    }

    return switch (result.check) {
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
