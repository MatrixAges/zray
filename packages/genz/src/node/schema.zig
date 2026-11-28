const std = @import("std");
const view = @import("view.zig");
const generated = @import("genz_options").generated;
const printer = if (generated) @import("generated_printer_module_range") else void;
pub const Ast = if (generated) std.meta.Child(std.meta.Elem(@FieldType(std.meta.Child(printer.Input), "ast"))) else void;
pub const Expressions = table("expressions");
pub const Statements = table("statements");
pub const Declarations = table("declarations");
pub const Fields = table("fields");
pub const Arms = table("arms");

fn table(comptime name: []const u8) type {
    return if (generated) std.meta.Child(@FieldType(Ast, name)) else void;
}

pub fn element(comptime Layout: type, comptime name: []const u8) type {
    return std.meta.Elem(@FieldType(Layout, name));
}

/// Dense payload groups follow the numeric tags of the Source layout.
pub fn payloadNames(comptime NativeTag: type, comptime Tag: type) [@typeInfo(Tag).@"enum".field_names.len][:0]const u8 {
    @setEvalBranchQuota(100_000);

    const native = @typeInfo(NativeTag).@"enum".field_names;
    const canonical = @typeInfo(Tag).@"enum".field_names;

    if (native.len != canonical.len) @compileError("AST payloads do not match the Source tags");

    var names: [canonical.len][:0]const u8 = undefined;

    for (canonical, &names, 0..) |name, *result, index| {
        if (@backingInt(@field(Tag, name)) != index) @compileError("AST payload tags must be dense");

        result.* = for (native) |field| {
            if (std.mem.eql(u8, view.pascal(field), name)) break field;
        } else @compileError("Source AST tag has no native constructor: " ++ name);
    }

    return names;
}
