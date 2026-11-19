const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const terms = @import("terms.zig");
const ports = @import("ports.zig");
const Expressions = @import("expressions.zig");
const Value = terms.Value;
const Self = @This();
const Graph = @import("graph.zig");
const declaration_buffer_size = 4 * 1024;

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
    if (self.program.type_only or self.program.stores.count() != 0) return self.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "symbolic execution requires a pure executable function without Store capabilities");

    self.input = try self.parameter(self.program.input_type, "in", port_allocator, .hardware);
    const output = try self.call();

    return .{ .inputs = self.inputs.items, .output = output, .definitions = self.graph.?.definitions.slice() };
}

pub fn generate(self: *Self, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator) zx.Error!Query {
    try self.ensureGraph();
    if (self.program.type_only or self.program.stores.count() != 0) return self.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "verification requires an executable pure function without Store capabilities");

    self.input = try self.parameter(self.program.input_type, "in", result_allocator, .verification);

    var precondition: []const u8 = "true";

    for (0..self.program.contracts.count()) |contract_index| {
        const contract = self.program.contracts.at(contract_index);

        if (contract.kind != .requires) continue;

        const evaluated = try self.evaluateContract(contract, null);

        try self.require(precondition, evaluated.safe);

        precondition = try self.conjunction(precondition, try self.conjunction(evaluated.safe, evaluated.value.scalar));
    }

    const environment = try self.scratch.allocator().alloc(?Value, self.program.symbols.count());

    @memset(environment, null);

    environment[0] = self.input;

    const remaining = try self.block(self.program.body.block(), environment, precondition);

    if (self.program.typeOf(self.program.output_type) == .scalar and self.program.typeOf(self.program.output_type).scalar == .void) {
        try self.postconditions(remaining, .{ .fields = &.{} });
    }

    const query_module = if (@import("parser_options").generated_parser) @import("generated_verification_query") else @import("query/seed.zig");
    const Request = @typeInfo(@TypeOf(query_module.executeValue)).@"fn".param_types[1].?;
    const Record = if (@typeInfo(Request) == .pointer) @typeInfo(Request).pointer.child else Request;
    var buffer: [declaration_buffer_size]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch);
    const graph = self.graph.?;
    const capacity = @max(buffer.len, graph.declaration_payload_bytes);
    var definitions = try std.Io.Writer.Allocating.initCapacity(memory.allocator(), capacity);

    defer definitions.deinit();

    try graph.writeDeclarations(&definitions.writer);

    const input: Record = .{
        .declarations = self.declarations.items,
        .definitions = definitions.written(),
        .violations = self.violations.items,
        .precondition = precondition,
    };

    const query = try query_module.executeValue(result_allocator, if (Record == Request) input else &input);

    return .{
        .feasibility = query.feasibility,
        .correctness = query.correctness,
        .inputs = self.inputs.items,
    };
}

const PortMode = enum { hardware, verification };

fn parameter(self: *Self, type_id: ir.TypeId, path: []const u8, port_allocator: std.mem.Allocator, comptime mode: PortMode) zx.Error!Value {
    const target = self.program.typeOf(type_id);

    if (target == .object or target == .tuple) {
        const count = if (target == .object) target.object.len else target.tuple.len;
        const fields = try self.allocator.alloc(Value, count);

        for (fields, 0..) |*field, index| {
            const child_path = try ports.fieldPath(port_allocator, path, if (target == .object) target.object.at(index).name else null, index);

            field.* = try self.parameter(if (target == .object) target.object.at(index).type_id else target.tuple.at(index), child_path, port_allocator, mode);
        }

        return .{ .fields = fields };
    }

    if (target == .scalar and target.scalar == .void) return .{ .fields = &.{} };

    const width = terms.symbolicWidth(target) orelse return self.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "verification currently supports boolean, enum and fixed-width integer inputs with static objects or tuples");
    const index = self.inputs.items.len;

    const symbol = if (mode == .hardware) try ports.name(port_allocator, index, false) else blk: {
        const members = if (target == .enumeration) target.enumeration.members.len else 0;
        const declared = try ports.parameter(port_allocator, index, width, members);

        try self.declarations.append(self.allocator, declared.declaration);
        if (declared.domain) |domain| try self.declarations.append(self.allocator, domain);

        break :blk declared.symbol;
    };

    try self.inputs.append(port_allocator, .{ .symbol = symbol, .path = path, .type_id = type_id });

    return .{ .scalar = symbol };
}

fn block(self: *Self, statements: ir.Block, environment: []?Value, initial: []const u8) zx.Error![]const u8 {
    const checkpoint = self.scratch.checkpoint();

    defer self.scratch.rewindRetainingCapacity(checkpoint);

    var path = initial;
    var evaluator = Expressions{ .allocator = self.allocator, .scratch = self.scratch, .program = self.program, .environment = environment, .graph = self.graph.?, .reporter = self.reporter, .call_depth = self.call_depth };

    // Scope validation gives each binding a unique slot and rejects reads outside its branch.
    for (0..statements.len) |statement_index| {
        const statement = statements.at(statement_index);

        switch (statement) {
            .evaluate => |id| {
                const value = try evaluator.evaluate(id);

                try self.require(path, value.safe);

                path = try self.conjunction(path, value.safe);
            },
            .constant => |binding| {
                const value = try evaluator.evaluate(binding.value);

                try self.require(path, value.safe);

                path = try self.conjunction(path, value.safe);

                environment[@backingInt(binding.symbol)] = value.value;
            },
            .destructure => |binding| {
                const value = try evaluator.evaluate(binding.value);

                try self.require(path, value.safe);

                path = try self.conjunction(path, value.safe);

                for (0..binding.symbols.len, value.value.fields) |symbol_index, field| {
                    const symbol = binding.symbols.at(symbol_index);

                    if (symbol) |id| environment[@backingInt(id)] = field;
                }
            },
            .result => |result| {
                const value = if (result) |id| try evaluator.evaluate(id) else terms.Evaluation{ .value = .{ .fields = &.{} } };

                try self.require(path, value.safe);

                const completed = try self.conjunction(path, value.safe);

                try self.postconditions(completed, value.value);
                try self.returns.append(self.allocator, .{ .path = completed, .value = value.value });

                return "false";
            },
            .branch => |branch| {
                const condition = try evaluator.evaluate(branch.condition);

                try self.require(path, condition.safe);

                path = try self.conjunction(path, condition.safe);
                const yes = try self.block(branch.yes, environment, try self.conjunction(path, condition.value.scalar));
                const no = try self.block(branch.no, environment, try self.excluding(path, condition.value.scalar));
                path = try self.disjunction(yes, no);
            },
            .switch_stmt => |selection| {
                const subject = try evaluator.evaluate(selection.subject);

                try self.require(path, subject.safe);

                path = try self.conjunction(path, subject.safe);
                var unmatched: []const u8 = "true";
                var continuation: []const u8 = "false";
                var fallback: ?ir.Block = null;

                for (0..selection.cases.len) |case_index| {
                    const case = selection.cases.at(case_index);

                    if (case.value) |id| {
                        const label = try evaluator.evaluate(id);
                        const matches = try terms.connect(self.allocator, .Equal, subject.value.scalar, label.value.scalar);
                        const remaining = try self.block(case.body, environment, try self.conjunction(path, matches));

                        continuation = try self.disjunction(continuation, remaining);
                        unmatched = try self.excluding(unmatched, matches);
                    } else fallback = case.body;
                }

                const default_path = try self.conjunction(path, unmatched);
                const remaining = if (fallback) |body| try self.block(body, environment, default_path) else default_path;

                path = try self.disjunction(continuation, remaining);
            },
            .parallel => |invocations| path = try self.parallel(&evaluator, invocations, path),
            else => return self.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "verification does not yet model this statement"),
        }
    }

    return path;
}

fn parallel(self: *Self, evaluator: *Expressions, invocations: @FieldType(ir.StatementRow, "parallel"), initial: []const u8) zx.Error![]const u8 {
    var parameter_path = initial;

    for (0..invocations.len) |invocation_index| {
        const invocation = invocations.at(invocation_index);
        const argument = self.program.expression(invocation.value).value.call.argument;
        const value = try evaluator.evaluate(argument);

        try self.require(parameter_path, value.safe);

        parameter_path = try self.conjunction(parameter_path, value.safe);
    }

    const launch_path = parameter_path;
    var joined_path = launch_path;
    const values = try self.allocator.alloc(terms.Evaluation, invocations.len);

    defer self.allocator.free(values);

    for (0..invocations.len, values) |invocation_index, *value| {
        const invocation = invocations.at(invocation_index);

        value.* = try evaluator.evaluate(invocation.value);

        try self.require(launch_path, value.safe);

        joined_path = try self.conjunction(joined_path, value.safe);
    }

    for (0..invocations.len, values) |invocation_index, value| {
        const invocation = invocations.at(invocation_index);

        if (invocation.symbol) |symbol| evaluator.environment[@backingInt(symbol)] = value.value;
    }

    return joined_path;
}

fn evaluateContract(self: *Self, clause: ir.Contract, output: ?Value) zx.Error!terms.Evaluation {
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

fn postconditions(self: *Self, path: []const u8, value: Value) zx.Error!void {
    var remaining = path;

    for (0..self.program.contracts.count()) |contract_index| {
        const clause = self.program.contracts.at(contract_index);

        if (clause.kind != .ensures) continue;

        const evaluated = try self.evaluateContract(clause, value);
        const valid = try self.conjunction(evaluated.safe, evaluated.value.scalar);

        try self.require(remaining, valid);

        remaining = try self.conjunction(remaining, valid);
    }
}

fn require(self: *Self, path: []const u8, predicate: []const u8) zx.Error!void {
    const condition = try self.excluding(path, predicate);

    try self.violations.append(self.allocator, condition);
}

fn conjunction(self: *Self, left: []const u8, right: []const u8) zx.Error![]const u8 {
    return self.boolean(try terms.connect(self.allocator, .And, left, right));
}

fn excluding(self: *Self, path: []const u8, predicate: []const u8) zx.Error![]const u8 {
    return self.boolean(try terms.exclude(self.allocator, path, predicate));
}

fn disjunction(self: *Self, left: []const u8, right: []const u8) zx.Error![]const u8 {
    return self.boolean(try terms.connect(self.allocator, .Or, left, right));
}

fn boolean(self: *Self, value: []const u8) zx.Error![]const u8 {
    return self.graph.?.bind(value, 0, .{ .file_name = self.program.file_name, .span = .{ .start = 0, .end = 0 } });
}

fn ensureGraph(self: *Self) zx.Error!void {
    if (self.graph != null) return;

    const graph = try self.allocator.create(Graph);
    graph.* = .{ .allocator = self.allocator, .reporter = self.reporter };
    self.graph = graph;
}

pub fn call(self: *Self) zx.Error!terms.Evaluation {
    try self.ensureGraph();

    const checkpoint = self.scratch.checkpoint();

    defer self.scratch.rewindRetainingCapacity(checkpoint);

    var path: []const u8 = "true";

    for (0..self.program.contracts.count()) |contract_index| {
        const contract = self.program.contracts.at(contract_index);

        if (contract.kind != .requires) continue;

        const evaluated = try self.evaluateContract(contract, null);
        const valid = try self.conjunction(evaluated.safe, evaluated.value.scalar);

        try self.require(path, valid);

        path = try self.conjunction(path, valid);
    }

    const environment = try self.scratch.allocator().alloc(?Value, self.program.symbols.count());

    @memset(environment, null);

    environment[0] = self.input;

    const remaining = try self.block(self.program.body.block(), environment, path);

    if (self.program.typeOf(self.program.output_type) == .scalar and self.program.typeOf(self.program.output_type).scalar == .void) {
        const unit = Value{ .fields = &.{} };

        try self.postconditions(remaining, unit);
        try self.returns.append(self.allocator, .{ .path = remaining, .value = unit });
    }

    if (self.returns.items.len == 0) return self.reporter.fail(.contract, .{ .start = 0, .end = 0 }, "verified call has no return value");

    var value = self.returns.items[0].value;
    var returned: []const u8 = "false";
    var safe: []const u8 = "true";

    for (self.returns.items) |result| {
        value = try self.graph.?.select(self.program, self.program.output_type, result.path, result.value, value, .{ .start = 0, .end = 0 });
        returned = try self.disjunction(returned, result.path);
    }

    for (self.violations.items) |violation| safe = try self.excluding(safe, violation);

    return .{ .value = value, .safe = try self.conjunction(safe, returned) };
}
