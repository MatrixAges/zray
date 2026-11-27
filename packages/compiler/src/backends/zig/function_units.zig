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

    var buffer: [2048]u8 align(@alignOf(u64)) = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());

    defer scratch.deinit();

    const plan = @import("generated_function_unit_plan");
    const Input = std.meta.Child(plan.Input);
    const input: Input = .{ .count = graph.count, .needed = needed, .regular = regular };

    const planned = zx.columns.invoke(plan.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const units = try allocator.alloc(Function, planned.len);

    for (planned, units) |item, *unit| {
        unit.* = .{ .id = @fromBackingInt(item.id), .regular = item.regular };
    }

    return units;
}
