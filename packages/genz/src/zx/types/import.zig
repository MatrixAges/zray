const std = @import("std");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
pub const Payloads = enum { copy, borrow_text, retain };
pub const Pending = std.ArrayList(node.Declaration);

/// Field names must outlive the AST; retained payloads already belong to its allocator.
pub fn append(self: *Lower, declarations: ?*Pending, comptime Output: type, output: anytype, fields: anytype, payloads: Payloads) Lower.Error!void {
    const Expressions = std.meta.Child(@FieldType(Output, "expressions"));
    const Definitions = std.meta.Child(@FieldType(Output, "definitions"));
    var expressions: Expressions = undefined;
    var definitions: Definitions = undefined;

    inline for (@typeInfo(Expressions).@"struct".field_names) |name| @field(expressions, name) = @field(output.expressions, name);
    inline for (@typeInfo(Definitions).@"struct".field_names) |name| @field(definitions, name) = @field(output.definitions, name);

    const combined = view.join(expressions, definitions);

    const imported = if (payloads == .retain)
        rows.appendBorrowed(self.allocator, &self.builder.nodes.expressions, &combined)

    else if (payloads == .borrow_text)
        rows.appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &combined)
    else
        rows.append(self.allocator, &self.builder.nodes.expressions, &combined);

    imported catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, fields) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    const constants = output.declarations;

    const staged = declarations orelse {
        const destination = &self.builder.nodes.declaration_rows;

        const result = if (payloads == .copy)
            rows.append(self.allocator, destination, constants)
        else
            rows.appendBorrowed(self.allocator, destination, constants);

        return result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    };

    try staged.ensureUnusedCapacity(self.allocator, constants.constant_name.len);

    for (constants.constant_name, constants.constant_type_expr, constants.constant_value, constants.constant_exported) |text, type_expr, value, exported| {
        const name = if (payloads == .copy) try self.allocator.dupe(u8, text) else text;

        staged.appendAssumeCapacity(.{ .constant = .{
            .name = name,
            .type_expr = if (type_expr) |id| @fromBackingInt(id) else null,
            .value = @fromBackingInt(value),
            .exported = exported,
        } });
    }
}
