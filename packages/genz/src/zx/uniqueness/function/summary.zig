const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Level = @import("../level.zig").Level;
const Memo = @import("../memo.zig");
const rows = @import("../row_output.zig");
const Context = @import("context.zig");
const settlement = @import("generated_uniqueness_function_settlement");
const Settlement = std.meta.Child(settlement.Input);
const Targets = std.meta.Child(@FieldType(Settlement, "targets"));

pub fn settle(function: *Function, owner: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Function.Settlement {
    var borrowed: Context = undefined;

    borrowed.init(function);

    var passed: rows.Contributions(Targets, "contributions") = undefined;
    var reads: rows.Reads(Targets) = undefined;

    passed.init();
    reads.init();

    const scratch = function.allocator;
    var scope = zx.memory.ArenaScope{ .active = scratch };

    const input: Settlement = .{
        .analysis = &.{
            .context = &borrowed.descriptor,
            .repeated = function.facts.repeated.owner,
            .operations = @ptrCast(function.operations),
            .inputs = @ptrCast(&function.summaries.input),
            .deferred = function.deferred,
            .results = function.facts.results,
            .count = count,
        },
        .targets = &.{
            .contributions = &.{ .storage = @ptrCast(&passed.buffer), .columns = &passed.view },
            .read_target = if (function.record_reads) &.{ .storage = @ptrCast(&reads.buffer), .columns = &reads.view } else null,
        },
        .arenas = &.{ .scope = @ptrCast(&scope), .scratch = @ptrCast(&scratch), .owner = @ptrCast(&owner) },
    };

    const result = zx.columns.invoke(settlement.executeValue, scope.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("function settlement failed: {s}", .{@errorName(err)}),
    };

    return .{ .passed = passed.rows(), .output = @ptrCast(result.levels), .changed = result.changed, .reads = reads.rows() };
}

pub fn retain(owner: std.mem.Allocator, passed: []const Function.Contribution, output: []const Level) std.mem.Allocator.Error!Memo.Settled {
    const retaining = @import("generated_uniqueness_result_retain");
    const Parameter = @typeInfo(@TypeOf(retaining.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    var result: rows.Contributions(Input, "target") = undefined;

    result.init();

    const input: Input = .{
        .source = zx.columns.storage.view(@FieldType(Input, "source"), passed),
        .target = &.{ .storage = @ptrCast(&result.buffer), .columns = &result.view },
        .output = @ptrCast(output),
    };

    const levels = retaining.executeValue(owner, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("contribution retention failed: {s}", .{@errorName(err)}),
    };

    return .{ .passed = result.rows(), .output = @ptrCast(levels) };
}
