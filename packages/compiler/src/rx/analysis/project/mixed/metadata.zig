const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
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

    if (calls.len != 0) {
        const context: Capture = .{ .calls = calls, .types = &types };

        if (comptime generated) {
            const rule = @import("generated_rx_capture_mixed_observations");
            const input: std.meta.Child(rule.Input) = .{ .capture = @ptrCast(&context), .count = calls.len, .functions = functions };
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            rule.executeIn(empty.allocator(), &input) catch unreachable;
        } else {
            for (calls, 0..) |*call, index| context.detach(index, call.callee.functions.count() == functions);
        }
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

const Capture = struct {
    calls: []Module.Call,
    types: *const ir.TypeTable,
    fn borrow(handle: *const anyopaque) *const Capture {
        return @ptrCast(@alignCast(handle));
    }
    fn detach(self: *const Capture, index: usize, shared: bool) void {
        const call = &self.calls[index];

        if (shared) call.callee.functions = .{};

        call.callee.types = self.types.*;
        call.callee.native_modules = .{};
        call.argument.types = self.types.*;
        call.argument.native_modules = .{};
        call.store_initializers = &.{};
    }
};

pub fn capturedMixedCallFunctions(handle: *const anyopaque, row: u64) u64 {
    return Capture.borrow(handle).calls[@intCast(row)].callee.functions.count();
}

pub fn detachMixedCall(handle: *const anyopaque, row: u64, shared: bool) void {
    Capture.borrow(handle).detach(@intCast(row), shared);
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
        const input: std.meta.Child(rule.Input) = .{ .target = @ptrCast(&target), .count = self.calls.len };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
    }

    for (self.calls, 0..) |*call, index| {
        if (call.callee.functions.count() == 0) try target.restorePrefix(index);

        target.restoreCall(index);
    }

    target.restoreReturn();
}

const Publication = struct {
    observed: *Self,
    allocator: std.mem.Allocator,
    functions: *const ir.FunctionTable,
    natives: *const ir.NativeModuleTable,
    initializers: @FieldType(frontend.AnalysisResult, "store_initializers"),
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
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

pub fn mixedCallNeedsPrefix(handle: *const anyopaque, row: u64) bool {
    return Publication.borrow(handle).observed.calls[@intCast(row)].callee.functions.count() == 0;
}

pub fn restoreMixedCallPrefix(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!void {
    try Publication.borrow(handle).restorePrefix(@intCast(row));
}

pub fn restoreMixedCallContext(handle: *const anyopaque, row: u64) void {
    Publication.borrow(handle).restoreCall(@intCast(row));
}

pub fn restoreMixedReturnContext(handle: *const anyopaque) void {
    Publication.borrow(handle).restoreReturn();
}
