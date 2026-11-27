const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const ir = zx.ir;
const Module = @import("../../module.zig");
const Flow = @import("../../flow_compile.zig");
const State = @import("state.zig");
const Self = @This();
const generated = @import("rx_options").generated_graph;

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

    if (comptime generated) {
        const rule = @import("generated_rx_capture_mixed_observations");
        const lists = functionRows(calls);
        var input: std.meta.Child(rule.Input) = .{ .functions = @ptrCast(&lists), .first = 0, .count = calls.len, .shared_functions = functions };
        const descriptor: *const std.meta.Child(rule.Input) = &input;
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        while (input.first < input.count) {
            const plan = zx.columns.invoke(rule.executeValue, empty.allocator(), descriptor) catch unreachable;

            for (calls[@intCast(input.first)..@intCast(plan.end)]) |*call| detach(call, types, plan.shared);

            input.first = plan.end;
        }
    } else {
        for (calls) |*call| detach(call, types, call.callee.functions.count() == functions);
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

fn functionRows(calls: []const Module.Call) zx.memory.ListColumn {
    return zx.memory.borrowSliceColumn(&.{ "callee", "functions", "files" }, calls);
}

fn detach(call: *Module.Call, types: ir.TypeTable, shared: bool) void {
    if (shared) call.callee.functions = .{};

    call.callee.types = types;
    call.callee.native_modules = .{};
    call.argument.types = types;
    call.argument.native_modules = .{};
    call.store_initializers = &.{};
}

/// Publishes the prefixes as they stood during analysis, using the project's final backing storage.
pub fn publish(self: *Self, state: *const State) std.mem.Allocator.Error!void {
    const functions = state.functions.view().prefix(self.functions);
    const natives = state.native_modules.view().prefix(self.natives);

    const target: Publication = .{
        .observed = self,
        .allocator = state.allocator,
        .functions = &functions,
        .natives = &natives,
        .initializers = state.initializers.items[0..self.initializers],
    };

    if (comptime generated) {
        const rule = @import("generated_rx_restore_mixed_observations");
        const lists = functionRows(self.calls);
        var input: std.meta.Child(rule.Input) = .{ .functions = @ptrCast(&lists), .first = 0, .count = self.calls.len };
        const descriptor: *const std.meta.Child(rule.Input) = &input;
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        while (input.first < input.count) {
            const plan = zx.columns.invoke(rule.executeValue, empty.allocator(), descriptor) catch unreachable;
            const first: usize = @intCast(input.first);
            const end: usize = @intCast(plan.end);

            for (first..end) |index| {
                if (plan.shared) try target.restorePrefix(index);

                target.restoreCall(index);
            }

            input.first = plan.end;
        }
    } else {
        for (self.calls, 0..) |*call, index| {
            if (call.callee.functions.count() == 0) try target.restorePrefix(index);

            target.restoreCall(index);
        }
    }

    target.restoreReturn();
}

const Publication = struct {
    observed: *Self,
    allocator: std.mem.Allocator,
    functions: *const ir.FunctionTable,
    natives: *const ir.NativeModuleTable,
    initializers: @FieldType(frontend.AnalysisResult, "store_initializers"),
    fn restorePrefix(self: *const Publication, index: usize) std.mem.Allocator.Error!void {
        const call = &self.observed.calls[index];

        call.callee.functions = if (call.callee_suffix) |tail|
            try frontend.project.artifact.function_table.join(self.allocator, self.functions.*, tail.*)

        else
            self.functions.*;

        call.callee_suffix = null;
    }
    fn restoreCall(self: *const Publication, index: usize) void {
        const call = &self.observed.calls[index];

        call.callee.native_modules = self.natives.*;
        call.argument.native_modules = self.natives.*;

        if (call.function_id != null) call.store_initializers = self.initializers;
    }
    fn restoreReturn(self: *const Publication) void {
        if (self.observed.result) |*result| result.native_modules = self.natives.*;
    }
};
