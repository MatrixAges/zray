const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const terms = @import("../terms.zig");
const execution = @import("context.zig");
const block = @import("block.zig");
const verify = @import("generated_verify_symbolic_program");
const hardware = @import("generated_model_symbolic_program");
const called = @import("generated_call_symbolic_program");
const Parameter = @import("output_execution_abi").layouts.@"zig:verification_program_host".Parameter;
const unit: terms.Value = .{ .fields = &.{} };

pub fn generate(conditions: *Conditions, result: std.mem.Allocator, temporary: std.mem.Allocator) zx.Error!Conditions.Query {
    var runner: Runner = .{ .conditions = conditions, .result_allocator = result };

    try runner.admit(verify, false);
    try runner.admit(verify, true);

    return @import("../query/output.zig").render(
        result,
        temporary,
        conditions.graph.?,
        runner.prefix,
        .{
            .declarations = conditions.declarations.items,
            .violations = conditions.violations,
            .precondition = runner.precondition,
        },
        conditions.inputs.items,
    );
}

pub fn model(conditions: *Conditions, result: std.mem.Allocator) zx.Error!Conditions.Model {
    var runner: Runner = .{ .conditions = conditions, .result_allocator = result };

    defer runner.release();

    try runner.admit(hardware, false);

    return .{
        .inputs = conditions.inputs.items,
        .output = runner.result,
        .definitions = conditions.graph.?.definitions.slice(),
    };
}

pub fn call(conditions: *Conditions) zx.Error!terms.Evaluation {
    var runner: Runner = .{ .conditions = conditions };

    defer runner.release();

    try runner.callPlan(null);

    return runner.result;
}

const Runner = struct {
    conditions: *Conditions,
    result_allocator: std.mem.Allocator = undefined,
    checkpoint: ?zx.Arena.Checkpoint = null,
    precondition: []const u8 = undefined,
    prefix: usize = undefined,
    continuation: []const u8 = undefined,
    result: terms.Evaluation = undefined,
    fn release(self: *const Runner) void {
        if (self.checkpoint) |checkpoint| self.conditions.scratch.rewindRetainingCapacity(checkpoint);
    }
    fn admit(self: *Runner, comptime rule: type, graph_ready: bool) zx.Error!void {
        const conditions = self.conditions;
        const Entry = std.meta.Child(rule.Input);
        const Ports = std.meta.Child(@FieldType(Entry, "types"));
        const table: *const zx.ir.TypeTable = &conditions.program.types;
        const types = zx.columns.borrow(Ports, table);

        const request: Entry = .{
            .types = &types,
            .input = @backingInt(conditions.program.input_type),
            .type_only = conditions.program.type_only,
            .stores = conditions.program.stores.count(),
            .returns_unit = returnsUnit(&conditions.program),
            .graph_ready = graph_ready,
        };

        const plan = rule.executeIn(self.result_allocator, &request) catch |err| return execution.failure(err);

        if (plan.diagnostic) |diagnostic| return reject(conditions, diagnostic);
        try self.run(plan.steps, plan.rows orelse &.{});
    }
    fn callPlan(self: *Runner, returned: ?u64) zx.Error!void {
        const conditions = self.conditions;

        const input: std.meta.Child(called.Input) = .{
            .returns_unit = returnsUnit(&conditions.program),
            .returned = returned,
        };

        var buffer: [512]u8 = undefined;
        var allocator = std.heap.BufferFirstAllocator.init(&buffer, conditions.allocator);
        const plan = called.executeIn(allocator.allocator(), &input) catch |err| return execution.failure(err);

        if (plan.diagnostic) |diagnostic| return reject(conditions, diagnostic);
        try self.run(plan.steps, &.{});
    }
    fn run(self: *Runner, steps: anytype, rows: []const *const Parameter) zx.Error!void {
        const conditions = self.conditions;

        for (steps) |step| switch (step) {
            .EnsureGraph => try conditions.ensureGraph(),
            .BeginCall => self.checkpoint = conditions.scratch.checkpoint(),
            .PublishParameter => {
                var remaining = rows;

                conditions.input = try parameter(conditions, self.result_allocator, &remaining);
            },
            .EntryPreconditions, .CallPreconditions => {
                const prepared = try execution.apply(conditions, if (step == .CallPreconditions) .Called else .Entry, &.{
                    .path = "true",
                    .violations = conditions.violations,
                }, null);

                self.precondition = prepared.path;
                conditions.violations = prepared.violations;
                self.prefix = conditions.graph.?.definitions.len;
            },
            .RunBody => self.continuation = try runBody(conditions, self.precondition),
            .CheckUnit => {
                const checked = try execution.apply(conditions, .Returned, &.{
                    .path = self.continuation,
                    .violations = conditions.violations,
                }, unit);

                conditions.violations = checked.violations;
            },
            .AppendUnit => try conditions.returns.append(conditions.allocator, .{ .path = self.continuation, .value = unit }),
            .Resolve => try self.callPlan(conditions.returns.items.len),
            .Merge => self.result = try execution.merge(conditions),
        };
    }
};

fn returnsUnit(program: *const zx.ir.Program) bool {
    const target = program.typeOf(program.output_type);

    return target == .scalar and target.scalar == .void;
}

fn reject(conditions: *Conditions, diagnostic: anytype) zx.Error {
    return conditions.reporter.fail(if (diagnostic.unsupported) .unsupported else .contract, .{ .start = 0, .end = 0 }, diagnostic.message);
}

fn runBody(conditions: *Conditions, path: []const u8) zx.Error![]const u8 {
    return block.execute(conditions, conditions.program.body.block(), path);
}

fn parameter(conditions: *Conditions, result: std.mem.Allocator, rows: *[]const *const Parameter) std.mem.Allocator.Error!terms.Value {
    const source = rows.*[0];

    rows.* = rows.*[1..];

    if (source.symbol) |symbol| {
        if (source.declaration) |text| try conditions.declarations.append(conditions.allocator, text);
        if (source.domain) |text| try conditions.declarations.append(conditions.allocator, text);
        try conditions.inputs.append(result, .{ .symbol = symbol, .path = source.path.?, .type_id = @fromBackingInt(source.type_id) });

        return .{ .scalar = symbol };
    }

    const fields = try conditions.allocator.alloc(terms.Value, @intCast(source.fields));

    for (fields) |*field| field.* = try parameter(conditions, result, rows);

    return .{ .fields = fields };
}
