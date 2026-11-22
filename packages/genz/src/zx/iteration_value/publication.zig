const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const Context = @import("root.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const fields = @import("../../node/import_fields.zig");
const statements = @import("../../node/import_statements.zig");
const evaluation = @import("../expressions/evaluate.zig");
const entry = @import("generated_publish_iteration_ast");
const Input = std.meta.Child(entry.Input);
const Mode = @FieldType(Input, "mode");
const Error = Lower.Error;
const Borrow = std.meta.Child(@import("generated_iteration_borrow_emit").Output);
const Types = std.meta.Child(@import("generated_iteration_types_emit").Output);
const Conversion = std.meta.Child(@import("generated_conversion_emit").Output);
const Transfer = std.meta.Child(@import("generated_iteration_transfer").Output);
const TypeCache = struct { ids: []const u32, values: []const u32 };

const Frame = struct {
    lowering: *Lower,
    context: ?*Context,
    body: ?*Sequence,
    expressions: @FieldType(Borrow, "expressions"),
    forms: ?@FieldType(Borrow, "forms"),
    layouts: ?@FieldType(Types, "layouts"),
    statements: ?@FieldType(Borrow, "statements"),
    fields: ?@FieldType(Borrow, "fields"),
    prefix: ?@FieldType(Borrow, "statements"),
    variables: ?@FieldType(Conversion, "variables"),
    record: ?@FieldType(Transfer, "record"),
    cache: ?TypeCache,
    serial: ?usize,
    uses_allocator: bool,
    label: ?[]const u8 = null,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub const Scope = struct {
    context: ?*Context = null,
    body: ?*Sequence = null,
};

pub fn write(self: *Lower, comptime mode: Mode, scope: Scope, output: anytype) Error!void {
    const result = if (mode == .Returned) output.result else output;

    if (!result.valid) return error.OutOfMemory;

    var frame: Frame = .{
        .lowering = self,
        .context = scope.context,
        .body = scope.body,
        .expressions = zx.columns.pointer(@FieldType(Frame, "expressions"), result.expressions),
        .forms = if (mode != .Types) zx.columns.pointer(@FieldType(Borrow, "forms"), result.forms) else null,
        .layouts = if (mode == .Types) result.layouts else null,
        .statements = if (mode != .Buffer) zx.columns.pointer(@FieldType(Borrow, "statements"), result.statements) else null,
        .fields = if (mode != .Transfer and mode != .PrepareBuffer) zx.columns.pointer(@FieldType(Borrow, "fields"), result.fields) else null,
        .prefix = switch (mode) {
            .Input => result.declarations,
            .Returned => output.storage,
            .Transfer => result.prefix,
            .PrepareBuffer => result.roots,
            else => null,
        },
        .variables = if (mode == .Input or mode == .Returned or mode == .Transfer) zx.columns.pointer(@FieldType(Conversion, "variables"), result.variables) else null,
        .record = if (mode == .Transfer) result.record else null,
        .cache = if (mode == .Types) .{ .ids = result.cache_types, .values = result.cache_values } else null,
        .serial = switch (mode) {
            .Projection, .Buffer, .PrepareBuffer => null,
            else => @intCast(result.serial),
        },
        .uses_allocator = switch (mode) {
            .Input, .Returned, .Mutation => result.uses_allocator,
            .Transfer, .PrepareBuffer => true,
            else => false,
        },
    };

    const input: Input = .{ .target = @ptrCast(&frame), .mode = mode };

    return evaluation.execute(entry, &input);
}

pub fn ownIterationLabel(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const labels = frame.expressions.block_label;

    frame.label = try frame.lowering.allocator.dupe(u8, labels[labels.len - 1]);
}

pub fn appendIterationExpressions(handle: *const anyopaque, borrow_text: bool) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const target = &self.builder.nodes.expressions;

    if (frame.layouts) |layouts| {
        const source = view.join(frame.expressions.*, layouts.*);

        rows.append(self.allocator, target, &source) catch |err| return failure(err);

        return;
    }

    const source = view.join(frame.expressions.*, frame.forms.?.*);

    if (borrow_text) {
        rows.appendBorrowingText(self.allocator, target, &source) catch |err| return failure(err);
    } else {
        rows.append(self.allocator, target, &source) catch |err| return failure(err);
    }

    if (frame.label) |label| {
        const labels = target.payloads.block.fields.label.values.items;

        labels[labels.len - 1] = label;
    }
}

pub fn appendIterationStatements(handle: *const anyopaque, borrow_text: bool, borrow_all: bool) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const target = &self.builder.nodes.statements;
    const source = frame.statements.?;

    if (borrow_all) {
        rows.appendBorrowed(self.allocator, target, source) catch |err| return failure(err);

        const labels = target.payloads.break_value.fields.label.values.items;

        labels[labels.len - 1] = frame.label.?;
    } else if (borrow_text) {
        rows.appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);
    } else {
        rows.append(self.allocator, target, source) catch |err| return failure(err);
    }
}

pub fn appendIterationFields(handle: *const anyopaque, own_text: bool) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const target = &self.builder.nodes.field_columns;

    if (own_text) {
        fields.append(self.allocator, target, frame.fields.?) catch |err| return failure(err);
    } else {
        _ = fields.appendBorrowingText(self.allocator, target, frame.fields.?) catch |err| return failure(err);
    }
}

pub fn appendIterationSequence(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.lowering.allocator;
    const body = frame.body.?;
    const prefix = frame.prefix orelse frame.statements.?;

    if (frame.variables) |variables| {
        const source = view.join(prefix.*, variables.*);

        statements.append(allocator, body, &source) catch |err| return failure(err);
    } else {
        statements.append(allocator, body, prefix) catch |err| return failure(err);
    }
}

pub fn cachePublishedIterationTypes(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const cache = frame.cache.?;

    return @import("resources.zig").publish(frame.context.?, cache.ids, cache.values);
}

pub fn recordIterationTransfer(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const record = frame.record.?;

    return frame.context.?.transfers.append(frame.lowering.allocator, .{
        .type_id = @fromBackingInt(record.type_id),
        .owner = @fromBackingInt(record.owner),
        .value = @fromBackingInt(record.value),
        .ready = @fromBackingInt(record.ready),
    });
}

pub fn finishIterationPublication(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    if (frame.serial) |serial| self.serial = serial;

    self.uses_allocator = self.uses_allocator or frame.uses_allocator;
}

pub fn hoistIterationStorage(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const source = view.join(frame.prefix.?.*, frame.variables.?.*);

    return frame.lowering.hoistReferences(&source);
}

fn failure(err: rows.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
