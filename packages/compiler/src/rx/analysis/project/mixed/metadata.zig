const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const Module = @import("../../module.zig");
const Flow = @import("../../flow_compile.zig");
const State = @import("state.zig");
const Self = @This();

calls: []Module.Call,
result: ?ir.Program,
functions: usize,
natives: usize,
initializers: usize,
/// Detaches the entry observations from the growable project columns before linking.
pub fn capture(flow: *Flow) std.mem.Allocator.Error!?*Self {
    const calls = flow.calls.items;

    if (calls.len == 0 and flow.root_return == null) return null;

    const options = flow.inputs;
    const types = (try flow.takeTypeStorage()).view();
    const functions = options.shared_functions.count();

    for (calls) |*call| {
        // A joined private Task table owns its columns. Shared prefixes are rebound after linking.
        if (call.callee.functions.count() == functions) call.callee.functions = .{};

        call.callee.types = types;
        call.callee.native_modules = .{};
        call.argument.types = types;
        call.argument.native_modules = .{};
        call.store_initializers = &.{};
    }

    const retained = try flow.allocator.create(Self);

    retained.* = .{
        .calls = calls,
        .result = if (flow.root_return) |value| value.* else null,
        .functions = functions,
        .natives = options.native_modules.count(),
        .initializers = options.store_initializers.len,
    };

    if (retained.result) |*result| {
        result.types = types;
        result.native_modules = .{};
    }

    return retained;
}

/// Publishes the prefixes as they stood during analysis, using the project's final backing storage.
pub fn publish(self: *Self, state: *const State) std.mem.Allocator.Error!void {
    const functions = state.functions.view().prefix(self.functions);
    const natives = state.native_modules.view().prefix(self.natives);
    const initializers = state.initializers.items[0..self.initializers];

    for (self.calls) |*call| {
        if (call.callee.functions.count() == 0) {
            call.callee.functions = if (call.callee_suffix) |tail|
                try frontend.project.artifact.function_table.join(state.allocator, functions, tail.*)

            else
                functions;

            call.callee_suffix = null;
        }

        call.callee.native_modules = natives;
        call.argument.native_modules = natives;

        if (call.function_id != null) call.store_initializers = initializers;
    }

    if (self.result) |*result| result.native_modules = natives;
}
