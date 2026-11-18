const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const rows = @import("../row_output.zig");
const publishing = @import("generated_uniqueness_result_settlement");
const Publication = std.meta.Child(publishing.Input);
const levels = @import("levels.zig");
const settlement = @import("generated_uniqueness_function_settlement");

pub fn settle(function: *Function, owner: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Function.Settlement {
    const Parameter = @typeInfo(@TypeOf(settlement.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    var borrowed: levels.Borrowed = undefined;

    try borrowed.init(function);

    const input: Input = .{
        .context = if (@typeInfo(@FieldType(Input, "context")) == .pointer) &borrowed.descriptor else borrowed.context,
        .repeated = @ptrCast(function.order.repeated),
        .operations = @ptrCast(function.operations),
        .inputs = @ptrCast(&function.summaries.input),
        .deferred = function.deferred,
        .results = @ptrCast(function.order.results),
        .count = count,
    };

    const result = settlement.executeValue(function.allocator, if (indirect) &input else input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("function settlement failed: {s}", .{@errorName(err)}),
    };

    function.evaluation = .{ .known = result.state.known, .carried = result.state.carried, .reads = result.state.reads };
    var passed: rows.Contributions(Publication, "contributions") = undefined;
    var reads: rows.Reads(Publication) = undefined;

    passed.init();
    reads.init();

    const input_rows: Publication = .{
        .passed = zx.columns.slice(@FieldType(Publication, "passed"), result.passed),
        .levels = zx.columns.slice(@FieldType(Publication, "levels"), result.levels),
        .reads = zx.columns.slice(@FieldType(Publication, "reads"), result.state.reads),
        .contributions = &.{ .storage = @ptrCast(&passed.buffer), .columns = &passed.view },
        .read_target = if (function.record_reads) &.{ .storage = @ptrCast(&reads.buffer), .columns = &reads.view } else null,
    };

    const output = zx.columns.invoke(publishing.executeValue, owner, &input_rows) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("settlement publication failed: {s}", .{@errorName(err)}),
    };

    return .{ .passed = passed.rows(), .output = @ptrCast(output), .changed = result.changed, .reads = reads.rows() };
}

pub fn retain(owner: std.mem.Allocator, passed: []const Function.Contribution) std.mem.Allocator.Error![]const Function.Contribution {
    const retaining = @import("generated_uniqueness_result_retain");
    const Parameter = @typeInfo(@TypeOf(retaining.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    var result: rows.Contributions(Input, "target") = undefined;

    result.init();

    const input: Input = .{
        .source = zx.columns.storage.view(@FieldType(Input, "source"), passed),
        .target = &.{ .storage = @ptrCast(&result.buffer), .columns = &result.view },
    };

    retaining.executeValue(owner, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("contribution retention failed: {s}", .{@errorName(err)}),
    };

    return result.rows();
}
