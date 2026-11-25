const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const Expressions = @import("expressions.zig");
const Value = terms.Value;
const Self = @This();
const Graph = @import("graph.zig");
const execution = @import("execution/context.zig");
const workflow = @import("execution/program.zig");

allocator: std.mem.Allocator,
scratch: *zx.Arena,
program: ir.Program,
reporter: *zx.Reporter,
declarations: std.ArrayList([]const u8) = .empty,
violations: std.ArrayList([]const u8) = .empty,
input: Value = undefined,
inputs: std.ArrayList(Input) = .empty,
returns: std.ArrayList(Return) = .empty,
call_depth: usize = 0,

graph: ?*Graph = null,
const Return = struct { path: []const u8, value: Value };

pub const Input = struct { symbol: []const u8, path: []const u8, type_id: ir.TypeId };
pub const Query = struct { feasibility: []const u8, correctness: []const u8, inputs: []const Input };
pub const Model = struct { inputs: []const Input, output: terms.Evaluation, definitions: Graph.Definitions.Slice };

pub fn model(self: *Self, port_allocator: std.mem.Allocator) zx.Error!Model {
    return workflow.model(self, port_allocator);
}

pub fn generate(self: *Self, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator) zx.Error!Query {
    return workflow.generate(self, result_allocator, scratch);
}

pub fn evaluateContract(self: *Self, clause: ir.Contract, output: ?Value) zx.Error!terms.Evaluation {
    const checkpoint = self.scratch.checkpoint();

    defer self.scratch.rewindRetainingCapacity(checkpoint);

    const environment = try self.scratch.allocator().alloc(?Value, clause.symbols.count());

    environment[0] = self.input;

    if (clause.kind == .ensures) environment[1] = output;

    var view = self.program;

    view.symbols = clause.symbols;
    view.expressions = clause.expressions;

    var evaluator = Expressions{ .allocator = self.allocator, .scratch = self.scratch, .program = view, .environment = environment, .graph = self.graph.?, .reporter = self.reporter };

    return evaluator.evaluate(clause.predicate);
}

pub fn postconditions(self: *Self, path: []const u8, value: Value) zx.Error!void {
    _ = try execution.apply(self, .Returned, path, value);
}

pub fn boolean(self: *Self, value: []const u8) zx.Error![]const u8 {
    return self.graph.?.bind(value, 0, .{ .file_name = self.program.file_name, .span = .{ .start = 0, .end = 0 } });
}

pub fn ensureGraph(self: *Self) std.mem.Allocator.Error!void {
    if (self.graph != null) return;

    const graph = try self.allocator.create(Graph);
    graph.* = .{ .allocator = self.allocator, .reporter = self.reporter };
    self.graph = graph;
}

pub fn call(self: *Self) zx.Error!terms.Evaluation {
    return workflow.call(self);
}
