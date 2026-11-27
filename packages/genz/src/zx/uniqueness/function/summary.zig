const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Level = @import("../level.zig").Level;
const Memo = @import("../memo.zig");
const rows = @import("../row_output.zig");

pub fn retain(owner: std.mem.Allocator, passed: []const Function.Contribution, output: []const Level) std.mem.Allocator.Error!Memo.Settled {
    const retaining = @import("generated_uniqueness_result_retain");
    const Input = std.meta.Child(retaining.Input);
    const source = rows.ContributionRows.init(passed);

    const input: Input = .{
        .source = &source.view(rows.Target(Input, "source")),
        .output = @ptrCast(output),
    };

    var scratch = std.heap.ArenaAllocator.init(owner);

    defer scratch.deinit();

    const result = zx.columns.invoke(retaining.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("contribution retention failed: {s}", .{@errorName(err)}),
    };

    return rows.settlement(owner, result);
}
