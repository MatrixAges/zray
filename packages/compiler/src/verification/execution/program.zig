const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const terms = @import("../terms.zig");
const execution = @import("context.zig");
const block = @import("block.zig");
const verify = @import("generated_verify_symbolic_program");
const hardware = @import("generated_model_symbolic_program");
const called = @import("generated_call_symbolic_program");
const native = @import("output_execution_abi").layouts.@"zig:verification_program_host";

const Frame = struct {
    conditions: *Conditions,
    result_allocator: std.mem.Allocator = undefined,
    checkpoint: ?zx.Arena.Checkpoint = null,
    precondition: native.Preconditions = undefined,
    result: terms.Evaluation = undefined,
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
    fn release(frame: *@This()) void {
        if (frame.checkpoint) |checkpoint| frame.conditions.scratch.rewindRetainingCapacity(checkpoint);
    }
};

const unit: terms.Value = .{ .fields = &.{} };

pub fn generate(conditions: *Conditions, result: std.mem.Allocator, temporary: std.mem.Allocator) zx.Error!Conditions.Query {
    var frame: Frame = .{ .conditions = conditions, .result_allocator = result };
    const planned = try runEntry(verify, &frame);

    if (planned.diagnostic) |diagnostic| return reject(conditions, diagnostic);

    const query = planned.query.?;

    return @import("../query/output.zig").render(
        result,
        temporary,
        conditions.graph.?,
        @intCast(query.prefix),
        .{
            .declarations = conditions.declarations.items,
            .violations = conditions.violations.items,
            .precondition = query.path,
        },
        conditions.inputs.items,
    );
}

pub fn model(conditions: *Conditions, result: std.mem.Allocator) zx.Error!Conditions.Model {
    var frame: Frame = .{ .conditions = conditions, .result_allocator = result };

    defer frame.release();

    if (try runEntry(hardware, &frame)) |diagnostic| return reject(conditions, diagnostic);

    return .{
        .inputs = conditions.inputs.items,
        .output = frame.result,
        .definitions = conditions.graph.?.definitions.slice(),
    };
}

pub fn call(conditions: *Conditions) zx.Error!terms.Evaluation {
    var frame: Frame = .{ .conditions = conditions };

    const input: std.meta.Child(called.Input) = .{
        .program = @ptrCast(&frame),
        .returns_unit = returnsUnit(&conditions.program),
    };

    defer frame.release();

    const diagnostic = called.executeIn(conditions.allocator, &input) catch |err| return execution.failure(err);

    if (diagnostic) |message| return reject(conditions, message);

    return frame.result;
}

fn returnsUnit(program: *const zx.ir.Program) bool {
    const target = program.typeOf(program.output_type);

    return target == .scalar and target.scalar == .void;
}

fn runEntry(comptime rule: type, frame: *Frame) zx.Error!rule.Output {
    const conditions = frame.conditions;
    const Input = std.meta.Child(rule.Input);
    const Ports = std.meta.Child(@FieldType(Input, "types"));
    const table: *const zx.ir.TypeTable = &conditions.program.types;
    const types = zx.columns.borrow(Ports, table);

    const request: Input = .{
        .program = @ptrCast(frame),
        .types = &types,
        .input = @backingInt(conditions.program.input_type),
        .type_only = conditions.program.type_only,
        .stores = conditions.program.stores.count(),
        .returns_unit = returnsUnit(&conditions.program),
    };

    return rule.executeIn(frame.result_allocator, &request) catch |err| return execution.failure(err);
}

fn reject(conditions: *Conditions, diagnostic: anytype) zx.Error {
    return conditions.reporter.fail(if (diagnostic.unsupported) .unsupported else .contract, .{ .start = 0, .end = 0 }, diagnostic.message);
}

pub fn ensureSymbolicGraph(handle: *anyopaque) std.mem.Allocator.Error!void {
    try Frame.borrow(handle).conditions.ensureGraph();
}

pub fn beginSymbolicCall(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.checkpoint = frame.conditions.scratch.checkpoint();
}

pub fn symbolicProgramPreconditions(handle: *anyopaque, is_called: bool) zx.Error!*const native.Preconditions {
    const frame = Frame.borrow(handle);
    const conditions = frame.conditions;
    const path = try execution.apply(conditions, if (is_called) .Called else .Entry, "true", null);

    frame.precondition = .{ .path = path, .prefix = conditions.graph.?.definitions.len };

    return &frame.precondition;
}

pub fn runSymbolicProgramBody(handle: *anyopaque, path: []const u8) zx.Error![]const u8 {
    const conditions = Frame.borrow(handle).conditions;
    const environment = try conditions.scratch.allocator().alloc(?terms.Value, conditions.program.symbols.count());

    @memset(environment, null);

    environment[0] = conditions.input;

    return block.execute(conditions, conditions.program.body.block(), environment, path);
}

pub fn checkSymbolicUnit(handle: *anyopaque, path: []const u8) zx.Error!void {
    _ = try execution.apply(Frame.borrow(handle).conditions, .Returned, path, unit);
}

pub fn appendSymbolicUnit(handle: *anyopaque, path: []const u8) std.mem.Allocator.Error!void {
    const conditions = Frame.borrow(handle).conditions;

    try conditions.returns.append(conditions.allocator, .{ .path = path, .value = unit });
}

pub fn publishSymbolicProgramResult(handle: *anyopaque) zx.Error!bool {
    const frame = Frame.borrow(handle);

    if (frame.conditions.returns.items.len == 0) return false;

    frame.result = try execution.merge(frame.conditions);

    return true;
}

pub fn publishSymbolicParameter(handle: *anyopaque, rows: []const *const native.Parameter) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    var remaining = rows;

    frame.conditions.input = try parameter(frame, &remaining);
}

fn parameter(frame: *Frame, rows: *[]const *const native.Parameter) std.mem.Allocator.Error!terms.Value {
    const source = rows.*[0];
    rows.* = rows.*[1..];
    const conditions = frame.conditions;

    if (source.symbol) |symbol| {
        if (source.declaration) |text| try conditions.declarations.append(conditions.allocator, text);
        if (source.domain) |text| try conditions.declarations.append(conditions.allocator, text);
        try conditions.inputs.append(frame.result_allocator, .{ .symbol = symbol, .path = source.path.?, .type_id = @fromBackingInt(source.type_id) });

        return .{ .scalar = symbol };
    }

    const fields = try conditions.allocator.alloc(terms.Value, @intCast(source.fields));

    for (fields) |*field| field.* = try parameter(frame, rows);

    return .{ .fields = fields };
}
