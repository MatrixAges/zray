const std = @import("std");
const Lower = @import("../lower.zig");
const Context = @import("root.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const view = @import("../../node/view.zig");
const dense = @import("../../node/import_rows.zig");
const statements = @import("../../node/import_statements.zig");
const fields = @import("../../node/import_fields.zig");
const failure = @import("../construction/publication.zig").failure;
const Error = Lower.Error;

pub const Mode = enum {
    Input,
    Returned,
    Borrow,
    Types,
    Transfer,
    Projection,
    Buffer,
    PrepareBuffer,
};

pub const Scope = struct {
    context: ?*Context = null,
    body: ?*Sequence = null,
};

inline fn deref(value: anytype) if (@typeInfo(@TypeOf(value)) == .pointer) std.meta.Child(@TypeOf(value)) else @TypeOf(value) {
    return if (@typeInfo(@TypeOf(value)) == .pointer) value.* else value;
}

pub fn write(self: *Lower, comptime mode: Mode, scope: Scope, output: anytype) Error!void {
    const result = if (mode == .Returned) output.result else output;

    if (!result.valid) return error.OutOfMemory;

    if (mode == .Types) {
        const expr_src = view.join(deref(result.expressions), deref(result.layouts));

        dense.append(self.allocator, &self.builder.nodes.expressions, &expr_src) catch |err| return failure(err);
    } else if (mode == .Buffer or mode == .PrepareBuffer) {
        const expr_src = view.join(deref(result.expressions), deref(result.forms));

        dense.appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &expr_src) catch |err| return failure(err);
    } else {
        const expr_src = view.join(deref(result.expressions), deref(result.forms));

        dense.append(self.allocator, &self.builder.nodes.expressions, &expr_src) catch |err| return failure(err);
    }

    switch (mode) {
        .Borrow => {
            try appendFields(self, result.fields, false);
            try appendBody(self, scope.body.?, result.statements);
        },
        .Types => {
            try appendFields(self, result.fields, true);
            try appendBody(self, scope.body.?, result.statements);

            if (scope.context) |ctx| {
                for (result.cache_types, result.cache_values) |id, value| {
                    try ctx.types.put(self.allocator, @fromBackingInt(id), @fromBackingInt(value));
                }
            }
        },
        .Transfer => {
            try appendStatements(self, result.statements, false);

            const body_src = view.join(deref(result.prefix), deref(result.variables));

            statements.append(self.allocator, scope.body.?, &body_src) catch |err| return failure(err);

            try scope.context.?.transfers.retain(self.allocator, result.record);
        },
        .PrepareBuffer => {
            try appendStatements(self, result.statements, true);
            try appendBody(self, scope.body.?, result.roots);
        },
        .Buffer => try appendFields(self, result.fields, false),
        .Input, .Returned, .Projection => {
            try appendStatements(self, result.statements, false);
            try appendFields(self, result.fields, false);
        },
    }

    if (mode != .Buffer and mode != .Projection) {
        self.serial = @intCast(result.serial);

        if (mode == .Transfer or mode == .PrepareBuffer) {
            self.uses_allocator = true;
        } else if (mode == .Input or mode == .Returned) {
            self.uses_allocator = self.uses_allocator or result.uses_allocator;
        }
    }

    if (mode == .Input) {
        const body_src = view.join(deref(result.declarations), deref(result.variables));

        statements.append(self.allocator, scope.body.?, &body_src) catch |err| return failure(err);
    }

    if (mode == .Returned) {
        const storage_src = view.join(deref(output.storage), deref(result.variables));

        try self.hoistReferences(&storage_src);
    }
}

fn appendStatements(self: *Lower, source: anytype, comptime borrow_text: bool) Error!void {
    const stmt_src = deref(source);

    if (borrow_text) {
        dense.appendBorrowingText(self.allocator, &self.builder.nodes.statements, &stmt_src) catch |err| return failure(err);
    } else {
        dense.append(self.allocator, &self.builder.nodes.statements, &stmt_src) catch |err| return failure(err);
    }
}

fn appendBody(self: *Lower, body: *Sequence, source: anytype) Error!void {
    const body_src = deref(source);

    statements.append(self.allocator, body, &body_src) catch |err| return failure(err);
}

fn appendFields(self: *Lower, source: anytype, comptime own_text: bool) Error!void {
    const field_src = deref(source);

    if (own_text) {
        fields.append(self.allocator, &self.builder.nodes.field_columns, &field_src) catch |err| return failure(err);
    } else {
        _ = fields.appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, &field_src) catch |err| return failure(err);
    }
}
