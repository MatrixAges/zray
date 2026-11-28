const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const terms = @import("../terms.zig");
const clauses = @import("generated_apply_symbolic_contracts");
pub const merge = @import("merge.zig").execute;
const Mode = @FieldType(std.meta.Child(clauses.Input), "mode");
const native = @import("output_execution_abi").layouts.@"zig:verification_host";
pub const Path = native.SymbolicPath;

pub fn apply(conditions: *Conditions, mode: Mode, path: *const Path, value: ?terms.Value) zx.Error!Path {
    const kinds = conditions.program.contracts.kinds;

    if (kinds.len == 0) return path.*;

    const Input = std.meta.Child(clauses.Input);
    var output: std.meta.Child(@typeInfo(@FieldType(Input, "output")).optional.child) = undefined;

    if (value) |symbolic| output = .{ .text = symbolic.scalar, .fields = std.mem.sliceAsBytes(symbolic.fields) };

    const input: Input = .{
        .source = @ptrCast(@as(*const Conditions, conditions)),
        .output = if (value != null) &output else null,
        .kinds = zx.columns.slice(@FieldType(Input, "kinds"), kinds),
        .selected = if (mode == .Returned) .Ensures else .Requires,
        .path = path.path,
        .violations = path.violations,
        .mode = mode,
    };

    const result = clauses.executeIn(conditions.allocator, &input) catch |err| return failure(err);

    return .{ .path = result.path, .violations = result.violations };
}

pub fn evaluateClause(allocator: std.mem.Allocator, source: *const anyopaque, row: u64, output: ?*const native.ContractValue) zx.Error!*const native.ClauseTerm {
    const conditions: *const Conditions = @ptrCast(@alignCast(source));
    const clause = conditions.program.contracts.at(@intCast(row));
    const value = if (output) |symbolic| terms.Value.borrow(symbolic.text, symbolic.fields) else null;
    const outcome = try conditions.evaluateContract(clause, value);
    const result = try allocator.create(native.ClauseTerm);

    result.* = .{ .safe = outcome.safe, .predicate = outcome.value.scalar.? };

    return result;
}

pub fn bindSymbolicBoolean(source: *const anyopaque, term: []const u8) zx.Error![]const u8 {
    const conditions: *const Conditions = @ptrCast(@alignCast(source));

    return conditions.boolean(term);
}

pub fn failure(err: anyerror) zx.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.InvalidSource, error.IndexOutOfBounds => error.InvalidSource,
        else => unreachable,
    };
}
