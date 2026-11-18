const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub fn admitted(ids: []const ir.FunctionId, count: usize) bool {
    if (ids.len == 0) return true;

    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_callee_ids");
        const input: std.meta.Child(rule.Input) = .{ .ids = @ptrCast(ids), .count = count };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }

    for (ids) |id| if (@backingInt(id) >= count) return false;

    return true;
}

pub fn programView(allocator: std.mem.Allocator, function: ir.Function, id: ir.FunctionId, functions: ir.FunctionTable, types: ir.TypeTable, native_modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.Program {
    var program = ir.Program{
        .file_name = function.file_name,
        .types = types,
        .input_type = function.input_type,
        .output_type = function.output_type,
        .output_ownership = function.output_ownership,
        .symbols = function.symbols,
        .expressions = function.expressions,
        .body = function.body,
        .contracts = function.contracts,
        .stores = function.stores,
        .store_mode = function.store_mode,
        .functions = functions,
        .native_modules = native_modules,
    };

    if (function.external != null) try @import("frontend").writeExternalEntry(allocator, &program, id);

    return program;
}
