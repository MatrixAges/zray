const std = @import("std");
const abi = @import("ir_abi");
pub const generated = @hasDecl(abi, "layouts");
pub const Columns = if (generated) abi.layouts.@"zig:memory/columns" else void;
pub const Expressions = if (generated) Columns.Expressions else void;
pub const Control = if (generated) Columns.Control else void;
pub const Types = if (generated) Columns.TypeColumns else void;
pub const Functions = if (generated) Columns.Complete else void;
pub const StoreMode = if (generated) Columns.StoreMode else enum { transaction, orchestration };

pub fn column(comptime Layout: type, comptime name: []const u8, comptime Native: type) type {
    if (Layout == void) return Native;

    const Field = @FieldType(Layout, name);

    if (Field != Native) @compileError("Incompatible IR column representation: " ++ name);

    return Field;
}

pub fn storage(comptime Table: type, comptime name: []const u8) type {
    return std.ArrayList(std.meta.Elem(@FieldType(Table, name)));
}

pub fn checkTable(comptime Layout: type, comptime Table: type) void {
    if (Layout == void) return;

    if (!std.meta.eql(@typeInfo(Layout).@"struct".field_names, @typeInfo(Table).@"struct".field_names)) {
        @compileError("IR column order does not match the Source layout");
    }
}

pub fn checkFields(comptime Layout: type, comptime Table: type) void {
    if (Layout == void) return;

    const names = @typeInfo(Table).@"struct".field_names;

    if (names.len != @typeInfo(Layout).@"struct".field_names.len) @compileError("IR column count does not match the Source layout");

    for (names) |name| {
        if (!@hasField(Layout, name)) @compileError("IR column is absent from the Source layout: " ++ name);
    }
}
