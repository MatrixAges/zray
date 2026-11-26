const std = @import("std");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const statements = @import("../../node/import_statements.zig");
const selected = @import("../../node/import_selected.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Projection = std.meta.Child(@import("generated_ownership_projection").Output);
const entry = @import("generated_publish_state_ast");

const Frame = struct {
    lower: *Lower,
    body: *Sequence,
    source: *const Projection,
    fn borrow(target: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(target));
    }
};

pub fn projection(self: *Lower, body: *Sequence, output: *const Projection) Lower.Error!void {
    const frame: Frame = .{ .lower = self, .body = body, .source = output };
    const result = output.result;

    const input: std.meta.Child(entry.Input) = .{
        .target = @ptrCast(&frame),
        .lower = @ptrCast(self),
        .segments = result.segments.len,
        .helper = result.declaration != null,
        .valid = result.valid,
        .serial = result.serial,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input);
}

pub fn appendAstExpressions(handle: *const anyopaque, index: u64) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const target = &self.builder.nodes.expressions;
    const segment = frame.source.result.segments[@intCast(index)];
    const source = view.join(segment.expressions.*, segment.forms.*);

    if (segment.borrow_text) {
        rows.appendBorrowingText(self.allocator, target, &source) catch |err| return imported(err);
    } else {
        rows.append(self.allocator, target, &source) catch |err| return imported(err);
    }
}

pub fn appendAstStatements(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const result = frame.source.result;
    const source = view.join(result.statements.*, result.variables.*);

    selected.append(self.allocator, &self.builder.nodes.statements, &source) catch |err| return imported(err);
}

pub fn appendAstStorage(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const result = frame.source.result;
    const source = view.join(result.storage.*, result.variables.*);

    return frame.lower.hoistReferences(&source);
}

pub fn appendAstHelper(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lower;
    const declaration = frame.source.result.declaration.?;
    const parameters = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, declaration.parameters) catch |err| return imported(err);

    try self.task_declarations.appendFunction(self.allocator, declaration.columns, parameters.start);
}

pub fn appendAstBody(handle: *const anyopaque, binding: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.lower.allocator;
    const part = if (binding) frame.source.binding else frame.source.body;
    const source = view.join(part.statements.*, part.variables.*);

    if (part.borrow_text) {
        statements.appendSelectedBorrowingText(allocator, frame.body, &source) catch |err| return imported(err);
    } else {
        statements.appendSelected(allocator, frame.body, &source) catch |err| return imported(err);
    }
}

fn imported(err: rows.Error) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid state AST publication"),
    };
}
