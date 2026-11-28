const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const Evaluation = terms.Evaluation;
const Self = @This();
const Graph = @import("graph.zig");
const source = @import("execution/expression.zig");
const Columns = source.Columns;
const Types = source.Types;

allocator: std.mem.Allocator,
scratch: *zx.Arena,
program: ir.Program,
environment: []terms.Binding,
reporter: *zx.Reporter,
graph: *Graph,
cache: std.AutoHashMapUnmanaged(ir.ExprId, Evaluation) = .empty,
columns: ?Columns = null,
types: ?Types = null,
depth: usize = 0,
call_depth: usize = 0,
pub fn evaluate(self: *Self, id: ir.ExprId) zx.Error!Evaluation {
    if (self.cache.get(id)) |result| return result;

    const table = &self.program.expressions;
    const row = @backingInt(id);
    const target: ir.TypeId = @fromBackingInt(table.types[row]);
    const span: zx.Span = .{ .start = @intCast(table.span_start[row]), .end = @intCast(table.span_end[row]) };

    try self.graph.step(span);

    const result = try self.retainAt(target, span, try source.execute(self, id, target, span));

    try self.cache.put(self.scratch.allocator(), id, result);

    return result;
}

pub fn retainAt(self: *Self, target: ir.TypeId, span: zx.Span, result: Evaluation) zx.Error!Evaluation {
    return .{
        .value = try self.graph.retain(self.program, target, result.value, span),
        .safe = try self.boolean(result.safe, span),
    };
}

pub fn boolean(self: *Self, value: []const u8, span: zx.Span) zx.Error![]const u8 {
    return self.graph.bind(value, 0, .{ .file_name = self.program.file_name, .span = span });
}
