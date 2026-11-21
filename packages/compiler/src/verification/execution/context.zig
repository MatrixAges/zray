const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const terms = @import("../terms.zig");
const clauses = @import("generated_apply_symbolic_contracts");
const merge_result = @import("generated_merge_symbolic_returns");
const Mode = @FieldType(std.meta.Child(clauses.Input), "mode");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";

pub const Frame = struct {
    conditions: *Conditions,
    value: ?terms.Value,
    clause: native.ClauseTerm = undefined,
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn apply(conditions: *Conditions, mode: Mode, path: []const u8, value: ?terms.Value) zx.Error![]const u8 {
    const kinds = conditions.program.contracts.kinds;

    if (kinds.len == 0) return path;

    var frame: Frame = .{ .conditions = conditions, .value = value };
    var values = [_][]const u8{path};
    const slot: [][]const u8 = &values;
    const Input = std.meta.Child(clauses.Input);

    const input: Input = .{
        .session = @ptrCast(&frame),
        .kinds = zx.columns.slice(@FieldType(Input, "kinds"), kinds),
        .selected = if (mode == .Returned) .Ensures else .Requires,
        .path = &values,
        .path_slot = @ptrCast(&slot),
        .mode = mode,
    };

    return clauses.executeIn(conditions.allocator, &input) catch |err| return failure(err);
}

pub fn merge(conditions: *Conditions) zx.Error!terms.Evaluation {
    var frame: Frame = .{ .conditions = conditions, .value = conditions.returns.items[0].value };

    const input: std.meta.Child(merge_result.Input) = .{
        .target = @ptrCast(&frame),
        .returns = conditions.returns.items.len,
        .violations = conditions.violations.items,
    };

    const safe = merge_result.executeIn(conditions.allocator, &input) catch |err| return failure(err);

    return .{ .value = frame.value.?, .safe = safe };
}

pub fn evaluateClause(handle: *const anyopaque, row: u64) zx.Error!*const native.ClauseTerm {
    const frame = Frame.borrow(handle);
    const conditions = frame.conditions;
    const clause = conditions.program.contracts.at(@intCast(row));
    const outcome = try conditions.evaluateContract(clause, frame.value);

    frame.clause = .{ .safe = outcome.safe, .predicate = outcome.value.scalar };

    return &frame.clause;
}

pub fn bindSymbolicBoolean(handle: *const anyopaque, term: []const u8) zx.Error![]const u8 {
    return Frame.borrow(handle).conditions.boolean(term);
}

pub fn publishClauseViolation(handle: *const anyopaque, term: []const u8) std.mem.Allocator.Error!void {
    const conditions = Frame.borrow(handle).conditions;

    try conditions.violations.append(conditions.allocator, term);
}

pub fn selectSymbolicReturn(handle: *const anyopaque, row: u64) zx.Error![]const u8 {
    const frame = Frame.borrow(handle);
    const conditions = frame.conditions;
    const current = &conditions.returns.items[@intCast(row)];

    frame.value = try conditions.graph.?.select(
        conditions.program,
        conditions.program.output_type,
        current.path,
        current.value,
        frame.value.?,
        .{ .start = 0, .end = 0 },
    );

    return current.path;
}

pub fn failure(err: anyerror) zx.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.InvalidSource, error.IndexOutOfBounds => error.InvalidSource,
        else => unreachable,
    };
}
