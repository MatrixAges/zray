const std = @import("std");
const State = @import("state.zig");
const generated = @import("rx_options").generated_graph;
const admission = if (generated) @import("generated_rx_mixed_body_admit") else void;
const Source = if (generated) @FieldType(std.meta.Child(admission.Input), "source") else enum { ZX, RX, Store };
pub const Action = if (generated) admission.Output else enum { Skip, MissingSignature, AnalyzeZX, LowerRX };

pub fn run(comptime rule: type, backing: std.mem.Allocator, input: *const std.meta.Child(rule.Input), host: anytype) State.Error!void {
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    return rule.executeIn(scratch.allocator(), input, host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.InvalidSourceGraph => error.InvalidSourceGraph,
        else => unreachable,
    };
}

pub fn effect(comptime rule: type) type {
    return std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
}

pub fn snapshot(comptime Store: type) std.meta.Child(Store) {
    return .{
        .step = .OpenZX,
        .checked = null,
        .entry = null,
        .message = null,
        .ready = false,
        .declared = false,
        .slots = 0,
    };
}

pub fn admit(state: *const State, index: usize) Action {
    const source: Source = switch (state.graph.sources.at(index)) {
        .zx => .ZX,
        .rx => .RX,
        .store => .Store,
    };

    const signature = if (source == .ZX) state.signature_indices[index] else 0;

    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: std.meta.Child(admission.Input) = .{ .source = source, .signature = signature };

        return @import("zx").columns.invoke(admission.executeValue, empty.allocator(), &input) catch unreachable;
    }

    return switch (source) {
        .ZX => if (signature == 0) .MissingSignature else if (signature < 0) .Skip else .AnalyzeZX,
        .RX => .LowerRX,
        .Store => .Skip,
    };
}

pub fn accept(state: *const State, original_native_modules: usize, original_initializers: usize, original_functions: usize, lowered_functions: ?usize) bool {
    if (comptime generated) {
        const rule = @import("generated_rx_mixed_body_accept");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(rule.Input) = .{
            .native_modules = state.native_modules.count(),
            .original_native_modules = original_native_modules,
            .initializers = state.initializers.items.len,
            .original_initializers = original_initializers,
            .functions = if (lowered_functions != null) state.functions.count() else original_functions,
            .original_functions = original_functions,
            .lowered_functions = if (lowered_functions) |count| count else null,
        };

        return @import("zx").columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }

    if (state.native_modules.count() != original_native_modules or state.initializers.items.len != original_initializers) return false;

    return if (lowered_functions) |count| count == original_functions or state.functions.count() == original_functions else true;
}
