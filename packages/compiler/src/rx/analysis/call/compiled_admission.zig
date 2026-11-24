const std = @import("std");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;

const Result = if (generated)
    @typeInfo(@TypeOf(@import("generated_rx_compiled_admission").executeValue(undefined, undefined))).error_union.payload
else
    enum { Executable, MissingFunction, Setter, Transaction };

pub fn check(function: ?zx.ir.FunctionId, functions: *const zx.ir.FunctionStorage, setter: bool) Result {
    if (comptime generated) {
        const rule = @import("generated_rx_compiled_admission");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input = facts(std.meta.Child(rule.Input), function, functions, setter);

        return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }

    const row = @backingInt(function orelse return .MissingFunction);

    if (setter) return .Setter;
    if (functions.stores.items[row].count() != 0 and functions.store_modes.items[row] != .orchestration) return .Transaction;

    return .Executable;
}

pub fn facts(comptime Input: type, function: ?zx.ir.FunctionId, functions: *const zx.ir.FunctionStorage, setter: bool) Input {
    const row = if (function) |id| @backingInt(id) else null;

    return .{
        .executable = function != null,
        .setter = setter,
        .has_stores = if (row) |index| functions.stores.items[index].count() != 0 else false,
        .orchestration = if (row) |index| functions.store_modes.items[index] == .orchestration else false,
    };
}
