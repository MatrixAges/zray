const std = @import("std");
const columns = @import("zx").columns;
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const view = @import("../../node/view.zig");
const dense = @import("../../node/import_rows.zig");
const sparse = @import("../../node/import_selected.zig");
const statements = @import("../../node/import_statements.zig");
const fields = @import("../../node/import_fields.zig");
const entry = @import("generated_publish_ast_fragment");
const Input = std.meta.Child(entry.Input);
const Kind = @FieldType(Input, "kind");
const Update = std.meta.Child(@import("generated_list_update").Output);
const Collection = std.meta.Child(@import("generated_emit_collection_rows").Output);
const Context = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Collection, "state")), "context"));
const Expressions = @FieldType(Update, "expressions");
const Forms = @FieldType(Update, "forms");
const Rows = @FieldType(Update, "statements");

const Frame = struct {
    lower: *Lower,
    sequence: ?*Sequence,
    expressions: Expressions,
    forms: Forms,
    statements: Rows,
    vars: ?@FieldType(Context, "variables"),
    subset: ?@FieldType(Update, "body"),
    roots: ?Rows,
    fields: ?@FieldType(Update, "fields"),
    fn borrow(target: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(target));
    }
};

pub fn write(self: *Lower, sequence: ?*Sequence, output: anytype, comptime kind: Kind) Lower.Error!void {
    const data = switch (kind) {
        .Growth => &output.result,
        .Collection => output.state.context,
        .Update, .Guard => output,
    };

    const expressions = if (kind == .Growth) columns.view(std.meta.Child(Expressions), data.expressions) else undefined;
    const forms = if (kind == .Growth) columns.view(std.meta.Child(Forms), data.forms) else undefined;

    const frame: Frame = .{
        .lower = self,
        .sequence = sequence,
        .expressions = if (kind == .Growth) &expressions else columns.pointer(Expressions, data.expressions),
        .forms = if (kind == .Growth) &forms else columns.pointer(Forms, data.forms),
        .statements = columns.pointer(Rows, data.statements),
        .vars = if (kind == .Collection) data.variables else null,
        .subset = switch (kind) {
            .Collection => columns.pointer(@FieldType(Update, "body"), output.state.body),
            .Update => output.body,
            else => null,
        },
        .roots = switch (kind) {
            .Growth => columns.pointer(Rows, data.body),
            .Guard => columns.pointer(Rows, output.roots),
            else => null,
        },
        .fields = switch (kind) {
            .Growth => if (output.fields) |source| columns.pointer(@FieldType(Update, "fields"), source) else null,
            .Collection, .Update => columns.pointer(@FieldType(Update, "fields"), output.fields),
            .Guard => null,
        },
    };

    const input: Input = .{
        .target = @ptrCast(&frame),
        .kind = kind,
        .sequence = sequence != null,
        .fields = frame.fields != null,
        .valid = if (kind == .Growth) data.valid else output.valid,
        .serial = switch (kind) {
            .Growth => data.serial,
            .Guard => 0,
            .Collection, .Update => output.serial,
        },
        .uses_allocator = kind != .Guard and output.uses_allocator,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input);
}

pub fn appendFragmentExpressions(handle: *const anyopaque, borrow_text: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const target = &frame.lower.builder.nodes.expressions;
    const allocator = frame.lower.allocator;
    const source = view.join(frame.expressions.*, frame.forms.*);

    if (borrow_text) {
        dense.appendBorrowingText(allocator, target, &source) catch |err| return failure(err);
    } else {
        dense.append(allocator, target, &source) catch |err| return failure(err);
    }
}

pub fn appendFragmentStatements(handle: *const anyopaque, kind: Kind) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const target = &frame.lower.builder.nodes.statements;
    const allocator = frame.lower.allocator;

    switch (kind) {
        .Growth => dense.append(allocator, target, frame.statements) catch |err| return failure(err),
        .Guard => dense.appendBorrowingText(allocator, target, frame.statements) catch |err| return failure(err),
        .Update => sparse.append(allocator, target, frame.statements) catch |err| return failure(err),
        .Collection => {
            const source = view.join(frame.statements.*, frame.vars.?.*);

            sparse.append(allocator, target, &source) catch |err| return failure(err);
        },
    }
}

pub fn appendFragmentBody(handle: *const anyopaque, kind: Kind, sequence: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.lower.allocator;

    if (!sequence) {
        dense.append(allocator, &frame.lower.builder.nodes.statements, frame.roots.?) catch |err| return failure(err);

        return;
    }

    const target = frame.sequence.?;

    switch (kind) {
        .Growth => statements.append(allocator, target, frame.roots.?) catch |err| return failure(err),
        .Guard => statements.appendBorrowingText(allocator, target, frame.roots.?) catch |err| return failure(err),
        .Collection, .Update => {
            var roots = frame.statements.*;
            roots.tags = frame.subset.?.tags;
            roots.offsets = frame.subset.?.offsets;

            if (kind == .Collection) {
                const source = view.join(roots, frame.vars.?.*);

                statements.appendSelected(allocator, target, &source) catch |err| return failure(err);
            } else {
                statements.appendSelected(allocator, target, &roots) catch |err| return failure(err);
            }
        },
    }
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

pub fn commitFragment(handle: *const anyopaque, serial: u64, uses_allocator: bool) void {
    const self = Frame.borrow(handle).lower;

    self.serial = @intCast(serial);
    self.uses_allocator = self.uses_allocator or uses_allocator;
}

pub fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
