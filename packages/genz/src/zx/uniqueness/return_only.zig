const std = @import("std");
const ir = @import("zx").ir;

pub fn create(allocator: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error![]const bool {
    const result = try allocator.alloc(bool, program.functions.count());
    const calls = @import("../entry_flags/seed.zig");

    for (result, 0..) |*value, index| {
        const function = program.functions.at(index);

        value.* = function.external == null and function.stores.count() == 0 and
            std.mem.indexOfScalar(std.meta.Child(@FieldType(ir.ControlTable, "statement_kinds")), function.body.control.statement_kinds, .Parallel) == null and
            calls.calls(function.expressions, function.contracts, result[0..index]);
    }

    return result;
}
