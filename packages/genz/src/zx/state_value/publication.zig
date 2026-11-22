const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const statements = @import("../../node/import_statements.zig");
const selected = @import("../../node/import_selected.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Projection = std.meta.Child(@import("generated_ownership_projection").Output);
const Conversion = std.meta.Child(@import("generated_state_conversion_emit").Output);
const entry = @import("generated_publish_state_ast");

const Frame = struct {
    lower: *Lower,
    binding: ?*Sequence,
    body: ?*Sequence,
    source: union(enum) {
        projection: *const Projection,
        conversion: *const Conversion,
    },
    fn borrow(target: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(target));
    }
};

pub fn projection(self: *Lower, body: *Sequence, output: *const Projection) Lower.Error!void {
    if (!output.result.valid) return error.OutOfMemory;

    const frame: Frame = .{ .lower = self, .binding = body, .body = body, .source = .{ .projection = output } };

    return publish(&frame, output.result.segments.len, output.result.declaration != null, false);
}

pub fn conversion(self: *Lower, binding: ?*Sequence, body: ?*Sequence, output: anytype) Lower.Error!void {
    if (!output.valid) return error.OutOfMemory;

    const frame: Frame = .{
        .lower = self,
        .binding = binding,
        .body = body,
        .source = .{ .conversion = zx.columns.pointer(*const Conversion, output) },
    };

    return publish(&frame, 1, false, true);
}

fn publish(frame: *const Frame, segments: usize, helper: bool, fields: bool) Lower.Error!void {
    const input: std.meta.Child(entry.Input) = .{
        .target = @ptrCast(frame),
        .segments = segments,
        .helper = helper,
        .fields = fields,
        .body = frame.body != null,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeIn(fixed.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn appendAstExpressions(handle: *const anyopaque, index: u64) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const target = &self.builder.nodes.expressions;

    switch (frame.source) {
        .projection => |output| {
            const segment = output.result.segments[@intCast(index)];
            const source = view.join(segment.expressions.*, segment.forms.*);

            if (segment.borrow_text) {
                rows.appendBorrowingText(self.allocator, target, &source) catch |err| return imported(err);
            } else {
                rows.append(self.allocator, target, &source) catch |err| return imported(err);
            }
        },
        .conversion => |output| {
            const source = view.join(output.expressions.*, output.forms.*);

            rows.append(self.allocator, target, &source) catch |err| return imported(err);
        },
    }
}

pub fn appendAstStatements(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;

    switch (frame.source) {
        inline else => |output, kind| {
            const result = if (kind == .projection) output.result else output;
            const source = view.join(result.statements.*, result.variables.*);

            selected.append(self.allocator, &self.builder.nodes.statements, &source) catch |err| return imported(err);
        },
    }
}

pub fn appendAstStorage(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    switch (frame.source) {
        inline else => |output, kind| {
            const result = if (kind == .projection) output.result else output;
            const source = view.join(result.storage.*, result.variables.*);

            try frame.lower.hoistReferences(&source);
        },
    }
}

pub fn appendAstHelper(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const declaration = frame.source.projection.result.declaration.?;
    const parameters = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, declaration.parameters) catch |err| return imported(err);

    try self.task_declarations.appendFunction(self.allocator, declaration.columns, parameters.start);
}

pub fn appendAstBody(handle: *const anyopaque, binding: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.lower.allocator;
    const target = (if (binding) frame.binding else frame.body).?;

    switch (frame.source) {
        .projection => |output| {
            const part = if (binding) output.binding else output.body;
            const source = view.join(part.statements.*, part.variables.*);

            if (part.borrow_text) {
                statements.appendSelectedBorrowingText(allocator, target, &source) catch |err| return imported(err);
            } else {
                statements.appendSelected(allocator, target, &source) catch |err| return imported(err);
            }
        },
        .conversion => |output| {
            const part = if (binding) output.borrow_storage else output.body;
            const source = view.join(part.*, output.variables.*);

            statements.appendSelected(allocator, target, &source) catch |err| return imported(err);
        },
    }
}

pub fn appendAstFields(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const output = frame.source.conversion;
    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, output.fields) catch |err| return imported(err);
}

pub fn finishAstPublication(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;

    switch (frame.source) {
        .projection => |output| self.serial = @intCast(output.result.serial),
        .conversion => |output| {
            self.serial = @intCast(output.serial);
            self.uses_allocator = self.uses_allocator or output.uses_allocator;
        },
    }
}

fn imported(err: rows.Error) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid state AST publication"),
    };
}
