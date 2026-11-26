const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
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

pub fn write(self: *Lower, request: ?Request, source: Source) Error!NodeId {
    const requested = switch (source) {
        .reference => |output| output.request,
        .regular => |regular| regular.output.request,
        .value => |value| value.output.request,
    };

    if (requested) {
        const entry = request.?;

        try self.function_requests.add(self.allocator, entry.id, entry.variant);
    }

    switch (source) {
        .reference => |output| {
            const fn_idx: ?usize = if (requested) output.nodes.identifier.len - 1 else null;

            try publish(self, output.nodes, fn_idx, null, &.{});

            return @fromBackingInt(output.root);
        },
        .regular => |regular| {
            const output = regular.output;
            const fn_idx: ?usize = if (requested) output.nodes.identifier.len - 1 else null;

            try publish(self, output.nodes, fn_idx, null, &.{});

            self.uses_allocator = true;
            self.uses_io = self.uses_io or regular.io;
            self.uses_process = self.uses_process or regular.process;

            return @fromBackingInt(output.root);
        },
        .value => |value| {
            const output = value.output;
            const fn_idx: ?usize = if (requested) 0 else null;
            const operand_idx: ?usize = if (output.name.len != 0) @intCast(output.name_index) else null;
            const name = if (operand_idx != null) try self.allocator.dupe(u8, output.name) else &.{};
            const expressions = view.join(output.context.expressions.*, output.context.forms.*);

            try publish(self, &expressions, fn_idx, operand_idx, name);

            if (output.body.tags.len != 0) {
                const names = [_][]const u8{name};
                var body = output.body.*;

                if (name.len != 0 and body.constant_name.len != 0) body.constant_name = &names;

                const body_source = view.join(body, output.context.variables.*);
                @import("../../node/import_statements.zig").appendSelectedBorrowingText(self.allocator, value.body.?, &body_source) catch |err| return failure(err);
            }

            self.serial = @intCast(output.context.serial);
            self.uses_allocator = self.uses_allocator or output.uses_allocator;

            return @fromBackingInt(output.root);
        },
    }
}

fn publish(self: *Lower, source: anytype, function_name: ?usize, operand_name: ?usize, name: []const u8) Error!void {
    const target = &self.builder.nodes.expressions;
    const names = &target.payloads.identifier.values;
    const first = names.items.len;
    const function = if (function_name) |index| try self.allocator.dupe(u8, source.identifier[index]) else null;

    rows.appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);

    if (function_name) |index| names.items[first + index] = function.?;
    if (operand_name) |index| names.items[first + index] = name;
}

fn failure(err: rows.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid call AST publication"),
    };
}
