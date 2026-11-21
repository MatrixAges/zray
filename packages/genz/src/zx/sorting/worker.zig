const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const emitting = @import("worker/emitting.zig");
const scope = @import("../functions/scope.zig");

pub const Result = struct { declaration: node.Declaration, io: bool, process: bool };

pub fn build(self: *Lower, value: ir.Transform, child: node.ExpressionId, errors: ?[]const []const u8) Lower.Error!Result {
    if (!@import("genz_options").generated_analysis) {
        const result = try @import("worker_seed.zig").build(self, value, child, errors);

        return .{ .declaration = result.declaration, .io = result.io, .process = result.process };
    }

    var worker = scope.inherit(self, .Sort);

    try scope.reserve(&worker, self.allocator, .Sort);

    const prepared = try emitting.prepare(self);
    var saved: [prepared.names.len][]const u8 = undefined;
    const names = @import("../scope/reuse.zig").bindNames(self, value.parameters, &prepared.names, &saved);

    defer names.restore(self);

    try @import("../state_value/locals.zig").registerOwned(&worker, value.parameters);

    const result = try worker.expr(value.body);
    var helpers: [2]std.ArrayList(node.Statement) = @splat(.empty);
    var elements: [2]node.ExpressionId = undefined;
    var used: [2]bool = undefined;

    for (value.parameters[0..2], prepared.raw, 0..) |symbol, raw, index| {
        used[index] = worker.used[@backingInt(symbol)];
        elements[index] = if (used[index]) try @import("../state_value/elements.zig").read(&worker, &helpers[index], self.program.expression(value.target).type_id, raw) else raw;
    }

    const output_type = try self.typeExpr(self.program.expression(value.body).type_id);

    return .{
        .declaration = try emitting.finish(self, .{
            .worker = &worker,
            .environment = value.parameters[2],
            .child = child,
            .output_type = output_type,
            .errors = errors,
            .value = result,
            .raw = prepared.raw,
            .elements = elements,
            .used = used,
            .helpers = .{ helpers[0].items, helpers[1].items },
        }),
        .io = worker.uses_io,
        .process = worker.uses_process,
    };
}
