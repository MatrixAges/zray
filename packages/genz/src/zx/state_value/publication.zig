const std = @import("std");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const statements = @import("../../node/import_statements.zig");
const selected = @import("../../node/import_selected.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Projection = std.meta.Child(@import("generated_ownership_projection").Output);

pub fn projection(self: *Lower, body: *Sequence, output: *const Projection) Lower.Error!void {
    const result = output.result;

    if (!result.valid) return error.OutOfMemory;

    const target = &self.builder.nodes.expressions;

    for (result.segments) |segment| {
        const source = view.join(segment.expressions.*, segment.forms.*);

        if (segment.borrow_text) {
            rows.appendBorrowingText(self.allocator, target, &source) catch |err| return imported(err);
        } else {
            rows.append(self.allocator, target, &source) catch |err| return imported(err);
        }
    }

    const stmt_source = view.join(result.statements.*, result.variables.*);

    selected.append(self.allocator, &self.builder.nodes.statements, &stmt_source) catch |err| return imported(err);

    const storage_source = view.join(result.storage.*, result.variables.*);

    try self.hoistReferences(&storage_source);

    if (result.declaration) |declaration| {
        const parameters = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, declaration.parameters) catch |err| return imported(err);

        try self.task_declarations.appendFunction(self.allocator, declaration.columns, parameters.start);
    }

    try appendBody(self, body, output.binding);
    try appendBody(self, body, output.body);

    self.serial = @intCast(result.serial);
}

fn appendBody(self: *Lower, body: *Sequence, part: anytype) Lower.Error!void {
    const source = view.join(part.statements.*, part.variables.*);

    if (part.borrow_text) {
        statements.appendSelectedBorrowingText(self.allocator, body, &source) catch |err| return imported(err);
    } else {
        statements.appendSelected(self.allocator, body, &source) catch |err| return imported(err);
    }
}

fn imported(err: rows.Error) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid state AST publication"),
    };
}
