const std = @import("std");
const zx = @import("zx");
const Function = @import("genz").zx.modules.FunctionUnit;

pub fn create(allocator: std.mem.Allocator, graph: @import("genz").zx.references.Reachability, regular: []const u8) std.mem.Allocator.Error![]Function {
    const needed = graph.needed;

    if (comptime !@import("parser_options").generated_parser) {
        const units = try allocator.alloc(Function, graph.count);
        var row: usize = 0;

        for (needed, 0..) |wanted, index| {
            if (!wanted) continue;

            units[row] = .{ .id = @fromBackingInt(@intCast(index)), .regular = regular.len != 0 and regular[index] != 0 };
            row += 1;
        }

        return units;
    }

    const plan = @import("generated_function_unit_plan");
    const Input = std.meta.Child(plan.Input);
    const Target = std.meta.Child(@FieldType(Input, "target"));
    var output: zx.memory.RowOutput(Function, Target, .{ .ids = &.{"id"}, .regular = &.{"regular"} }) = undefined;

    output.init();
    errdefer allocator.free(output.rows());

    const input: Input = .{ .count = graph.count, .needed = needed, .regular = regular, .storage = @ptrCast(&output.buffer), .target = &output.view };

    zx.columns.invoke(plan.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return output.rows();
}
