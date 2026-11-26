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
    temporary: std.mem.Allocator = undefined,
    checkpoint: ?zx.Arena.Checkpoint = null,
    prefix: usize = undefined,
    query: Conditions.Query = undefined,
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
    var frame: Frame = .{ .conditions = conditions, .result_allocator = result, .temporary = temporary };

    try runEntry(verify, &frame);

    return frame.query;
}

pub fn model(conditions: *Conditions, result: std.mem.Allocator) zx.Error!Conditions.Model {
    var frame: Frame = .{ .conditions = conditions, .result_allocator = result };

    defer frame.release();

    try runEntry(hardware, &frame);

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
    called.executeIn(conditions.allocator, &input) catch |err| return execution.failure(err);

    return frame.result;
}

fn returnsUnit(program: *const zx.ir.Program) bool {
    const target = program.typeOf(program.output_type);

    return target == .scalar and target.scalar == .void;
}

fn runEntry(comptime rule: type, frame: *Frame) zx.Error!void {
    const conditions = frame.conditions;
    const Input = std.meta.Child(rule.Input);
    const Ports = std.meta.Child(@FieldType(Input, "types"));
    const table: *const zx.ir.TypeTable = &conditions.program.types;
    const types = zx.columns.borrow(Ports, table);

    const request: Input = .{
        .program = @ptrCast(frame),
        .target = @ptrCast(&conditions.input),
        .types = &types,
        .input = @backingInt(conditions.program.input_type),
        .type_only = conditions.program.type_only,
        .stores = conditions.program.stores.count(),
        .returns_unit = returnsUnit(&conditions.program),
    };

    rule.executeIn(frame.result_allocator, &request) catch |err| return execution.failure(err);
}

pub fn ensureSymbolicGraph(handle: *anyopaque) std.mem.Allocator.Error!void {
    try Frame.borrow(handle).conditions.ensureGraph();
}

pub fn beginSymbolicCall(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.checkpoint = frame.conditions.scratch.checkpoint();
}

pub fn rejectSymbolicProgram(handle: *anyopaque, message: []const u8) error{InvalidSource}!void {
    return @errorCast(Frame.borrow(handle).conditions.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, message));
}

pub fn symbolicProgramPreconditions(handle: *anyopaque, is_called: bool) zx.Error![]const u8 {
    const conditions = Frame.borrow(handle).conditions;

    return execution.apply(conditions, if (is_called) .Called else .Entry, "true", null);
}

pub fn markSymbolicQueryPrefix(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.prefix = frame.conditions.graph.?.definitions.len;
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

pub fn publishSymbolicQuery(handle: *anyopaque, path: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const conditions = frame.conditions;

    frame.query = try @import("../query/output.zig").render(
        frame.result_allocator,
        frame.temporary,
        conditions.graph.?,
        frame.prefix,
        .{
            .declarations = conditions.declarations.items,
            .violations = conditions.violations.items,
            .precondition = path,
        },
        conditions.inputs.items,
    );
}

pub fn rejectSymbolicReturn(handle: *anyopaque, message: []const u8) error{InvalidSource}!void {
    return @errorCast(Frame.borrow(handle).conditions.reporter.fail(.contract, .{ .start = 0, .end = 0 }, message));
}

pub fn publishSymbolicProgramResult(handle: *anyopaque) zx.Error!bool {
    const frame = Frame.borrow(handle);

    if (frame.conditions.returns.items.len == 0) return false;

    frame.result = try execution.merge(frame.conditions);

    return true;
}

pub fn reserveSymbolicParameter(handle: *anyopaque, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const conditions = Frame.borrow(handle).conditions;
    const fields = try conditions.allocator.alloc(terms.Value, @intCast(count));

    targetValue(target).* = .{ .fields = fields };
}

pub fn symbolicParameterField(target: *anyopaque, index: u64) *native.ParameterTarget {
    return @ptrCast(&targetValue(target).fields[@intCast(index)]);
}

pub fn appendSymbolicDeclaration(handle: *anyopaque, text: []const u8) std.mem.Allocator.Error!void {
    const conditions = Frame.borrow(handle).conditions;

    try conditions.declarations.append(conditions.allocator, text);
}

pub fn publishSymbolicParameter(handle: *anyopaque, target: *anyopaque, type_id: u32, path: []const u8, symbol: []const u8) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    try frame.conditions.inputs.append(frame.result_allocator, .{ .symbol = symbol, .path = path, .type_id = @fromBackingInt(type_id) });

    targetValue(target).* = .{ .scalar = symbol };
}

fn targetValue(target: *anyopaque) *terms.Value {
    return @ptrCast(@alignCast(target));
}
