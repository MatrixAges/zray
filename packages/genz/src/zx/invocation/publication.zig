const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Variant = @import("../functions/requests.zig").Variant;
const Reference = std.meta.Child(@import("generated_function_reference").Output);
const Regular = std.meta.Child(@import("generated_regular_call_emit").Output);
const Value = std.meta.Child(@import("generated_value_call_emit").Output);
const NodeId = @import("../../node.zig").ExpressionId;
const Error = Lower.Error;
const Request = struct { id: ir.FunctionId, variant: Variant };

const Source = union(enum) {
    reference: *const Reference,
    regular: struct { output: *const Regular, io: bool, process: bool },
    value: struct { output: *const Value, body: ?*Sequence },
};

pub const Publication = struct {
    lowering: *Lower,
    request: ?Request,
    source: Source,
    name: []const u8 = &.{},
    fn borrow(handle: *const anyopaque) *Publication {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn write(self: *Lower, request: ?Request, source: Source) Error!NodeId {
    const entry = @import("generated_publish_call_ast");
    var frame: Publication = .{ .lowering = self, .request = request, .source = source };

    const input: std.meta.Child(entry.Input) = .{
        .target = @ptrCast(&frame),
        .request = switch (source) {
            .reference => |output| output.request,
            .regular => |regular| regular.output.request,
            .value => |value| value.output.request,
        },
        .value_call = source == .value,
        .identifiers = switch (source) {
            .reference => |output| output.nodes.identifier.len,
            .regular => |regular| regular.output.nodes.identifier.len,
            .value => |value| value.output.context.expressions.identifier.len,
        },
        .operand = if (source == .value and source.value.output.name.len != 0) source.value.output.name_index else null,
        .body = source == .value and source.value.output.body.tags.len != 0,
    };

    try evaluation.execute(entry, &input);

    return @fromBackingInt(switch (source) {
        .reference => |output| output.root,
        .regular => |regular| regular.output.root,
        .value => |value| value.output.root,
    });
}

pub fn registerCallReference(handle: *const anyopaque) Error!void {
    const frame = Publication.borrow(handle);
    const request = frame.request.?;

    return frame.lowering.function_requests.add(frame.lowering.allocator, request.id, request.variant);
}

pub fn publishCallExpressions(handle: *const anyopaque, function_name: ?u64, operand_name: ?u64) Error!void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;

    switch (frame.source) {
        .reference => |output| try publish(self, output.nodes, function_name, null, &.{}),
        .regular => |regular| try publish(self, regular.output.nodes, function_name, null, &.{}),
        .value => |value| {
            const output = value.output;

            if (operand_name != null) frame.name = try self.allocator.dupe(u8, output.name);

            const expressions = view.join(output.context.expressions.*, output.context.forms.*);

            try publish(self, &expressions, function_name, operand_name, frame.name);
        },
    }
}

fn publish(self: *Lower, source: anytype, function_name: ?u64, operand_name: ?u64, name: []const u8) Error!void {
    const target = &self.builder.nodes.expressions;
    const names = &target.payloads.identifier.values;
    const first = names.items.len;
    const function = if (function_name) |index| try self.allocator.dupe(u8, source.identifier[@intCast(index)]) else null;

    rows.appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);

    if (function_name) |index| names.items[first + @as(usize, @intCast(index))] = function.?;
    if (operand_name) |index| names.items[first + @as(usize, @intCast(index))] = name;
}

pub fn publishCallBody(handle: *const anyopaque) Error!void {
    const frame = Publication.borrow(handle);
    const value = frame.source.value;
    const output = value.output;
    const names = [_][]const u8{frame.name};
    var body = output.body.*;

    if (frame.name.len != 0 and body.constant_name.len != 0) body.constant_name = &names;

    const source = view.join(body, output.context.variables.*);
    @import("../../node/import_statements.zig").appendSelectedBorrowingText(frame.lowering.allocator, value.body.?, &source) catch |err| return failure(err);
}

pub fn finishCallPublication(handle: *const anyopaque) void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;

    switch (frame.source) {
        .reference => {},
        .regular => |regular| {
            self.uses_allocator = true;
            self.uses_io = self.uses_io or regular.io;
            self.uses_process = self.uses_process or regular.process;
        },
        .value => |value| {
            self.serial = @intCast(value.output.context.serial);
            self.uses_allocator = self.uses_allocator or value.output.uses_allocator;
        },
    }
}

fn failure(err: rows.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid call AST publication"),
    };
}
