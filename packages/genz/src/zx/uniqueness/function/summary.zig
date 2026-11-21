const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Level = @import("../level.zig").Level;
const Memo = @import("../memo.zig");
const rows = @import("../row_output.zig");

pub fn retain(owner: std.mem.Allocator, passed: []const Function.Contribution, output: []const Level) std.mem.Allocator.Error!Memo.Settled {
    const retaining = @import("generated_uniqueness_result_retain");
    const Parameter = @typeInfo(@TypeOf(retaining.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    var result: rows.Contributions(Input, "target") = undefined;

    result.init();

    const source = rows.ContributionRows.init(passed);

    const input: Input = .{
        .source = &source.view(rows.Target(Input, "source")),
        .target = &.{ .storage = @ptrCast(&result.buffer), .columns = &result.view },
        .output = @ptrCast(output),
    };

    const levels = retaining.executeValue(owner, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("contribution retention failed: {s}", .{@errorName(err)}),
    };

    return .{ .passed = result.rows(), .output = @ptrCast(levels) };
}
