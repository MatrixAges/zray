const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Module = @import("../module.zig");
const Frame = @import("history.zig").Frame;
const State = @import("mixed/state.zig");
const Inputs = @import("call_inputs.zig");
const Schedule = @import("mixed/schedule.zig");
const Ahead = @import("mixed/ahead.zig");
const Reuse = @import("mixed/reuse.zig");
const Publication = @import("mixed/publication.zig");
const Dispatch = @import("mixed/schedule/dispatch.zig").Result;
const Export = @import("../project.zig").Export;
const generated = @import("rx_options").generated_graph;
const Action = if (generated) @import("rx_execution_abi").layouts.@"zig:rx_project_host".MixedAction else void;

/// Analyze and link each module in dependency order over the shared signature tables.
pub fn compile(allocator: std.mem.Allocator, backing: std.mem.Allocator, derived: Frame, selected: []const rx.ModuleSource, sources: []const frontend.project.Source, exports: []const Export, cache: *frontend.project.ParseCache, record: ?*@import("history.zig").History, arguments: *const Inputs) std.mem.Allocator.Error!Module.Value {
    const dependencies = derived.dependencies;
    const loaded = derived.loaded;

    var state = State.init(allocator, backing, dependencies, derived.signatures, derived.signature_indices, derived.types, loaded.project) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = .{ .path = dependencies.modules.items(.path)[dependencies.entry], .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "contract", .message = "source signatures cannot initialize the shared compilation context" } };
    };

    defer state.scratch.deinit();

    var prefix: Reuse.Prefix = undefined;
    var output: Module.Contract = undefined;

    var transaction: Transaction = .{
        .state = &state,
        .derived = &derived,
        .selected = selected,
        .sources = sources,
        .exports = exports,
        .cache = cache,
        .keep_skipped = record != null,
        .arguments = arguments,
        .reuse = try Reuse.begin(&state, cache, record, derived, sources, &prefix),
        .output = &output,
    };

    defer transaction.ahead.deinit();

    transaction.execute() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSourceGraph => return .{ .diagnostic = state.issue.? },
    };

    return .{ .contract = output };
}

const Transaction = struct {
    const Error = State.Error;
    state: *State,
    derived: *const Frame,
    selected: []const rx.ModuleSource,
    sources: []const frontend.project.Source,
    exports: []const Export,
    cache: *frontend.project.ParseCache,
    keep_skipped: bool,
    arguments: *const Inputs,
    reuse: Reuse,
    ahead: Ahead = .{},
    entry: ?*@import("mixed/metadata.zig") = null,
    pending: Dispatch = undefined,
    output: *Module.Contract,
    fn execute(self: *Transaction) Error!void {
        if (comptime generated) {
            const entry = @import("generated_rx_execute_mixed");

            const input: std.meta.Child(entry.Input) = .{
                .state = @ptrCast(self),
                .length = self.derived.dependencies.order.len,
                .has_exports = self.exports.len != 0,
                .retain = self.keep_skipped,
            };

            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), &input) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSourceGraph => error.InvalidSourceGraph,
                else => unreachable,
            };
        }

        return self.executeSeed();
    }
    fn executeSeed(self: *Transaction) Error!void {
        const state = self.state;
        const dependencies = &self.derived.dependencies;
        var window: Schedule.Window = .{ .first = 0, .end = 0 };
        var batch: usize = 0;
        var position: usize = 0;

        while (position < dependencies.order.len) {
            if (window.first == position) {
                if (window.first == window.end) {
                    window.end = dependencies.batch_ends[batch];
                    batch += 1;
                }

                window.first += try self.prefetch(window);
            }

            position = try self.reuse.reuse(state, position, window.first);

            const next = self.ahead.next(state, position, window.first, self.keep_skipped) orelse {
                position = window.first;

                continue;
            };

            state.owner = next.index;

            switch (next.action) {
                .Skip => {},
                .MissingSignature => return self.reject(next.index),
                .AnalyzeZX => try self.analyze(next),
                .LowerRX => try self.lower(next),
            }

            self.reuse.analyzed(state, next.index, next.position);

            position = next.following;
        }

        try self.materialize();
        try self.publishExports();

        self.reuse.finish(state, self.selected, self.sources);
    }

    fn prefetch(self: *Transaction, window: Schedule.Window) std.mem.Allocator.Error!usize {
        const consumed = try self.ahead.analyze(self.state, self.cache, self.sources, self.derived.*, &self.reuse, window, self.arguments);

        std.debug.assert(consumed != 0 and consumed <= window.end - window.first);

        return consumed;
    }
    fn materialize(self: *Transaction) Error!void {
        self.output.* = try Publication.materialize(self.state, self.derived, self.entry, self.exports.len != 0);
    }

    fn publishExports(self: *Transaction) Error!void {
        self.output.exports = try @import("mixed/exports.zig").collect(self.state, self.exports, self.derived.export_roots);
    }

    fn reject(self: *Transaction, index: usize) error{InvalidSourceGraph} {
        const state = self.state;

        state.issue = .{
            .path = state.graph.modules.items(.path)[index],
            .location = .{ .offset = 0, .line = 1, .column = 1 },
            .code = "module",
            .message = "source module signature is missing",
        };

        return error.InvalidSourceGraph;
    }
    fn analyze(self: *Transaction, next: Dispatch) Error!void {
        const state = self.state;
        const index = next.index;
        const module = @import("mixed/zx.zig");

        const loaded = try self.ahead.link(state, next.prepared_row) orelse
            try module.compile(state, self.cache, self.sources, index, null);

        state.finished.set(index, loaded);
    }
    fn lower(self: *Transaction, next: Dispatch) Error!void {
        const state = self.state;
        const index = next.index;
        const derived = self.derived;
        const source = derived.dependencies.sources.at(index).rx;
        const module = @import("mixed/rx.zig");

        const linked = if (self.ahead.lowered(state, next.prepared_row)) |lowered| ready: {
            _ = state.scratch.reset(.retain_capacity);

            break :ready try module.link(state, lowered.prepared, lowered.body);
        } else try module.compile(state, self.cache, self.sources, index, derived.loaded.modules[source], derived.resolved.at(source), self.arguments.module(source));

        state.finished.set(index, linked.loaded);

        if (linked.metadata) |metadata| self.entry = metadata;
    }
};

fn borrow(handle: *const anyopaque) *Transaction {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn mixedBatchEnd(handle: *const anyopaque, batch: u64) u64 {
    return borrow(handle).derived.dependencies.batch_ends[@intCast(batch)];
}

pub fn prefetchMixedWindow(handle: *const anyopaque, first: u64, end: u64) std.mem.Allocator.Error!u64 {
    return try borrow(handle).prefetch(.{ .first = @intCast(first), .end = @intCast(end) });
}

pub fn restoreMixedPrefix(handle: *const anyopaque, first: u64, limit: u64) std.mem.Allocator.Error!u64 {
    const self = borrow(handle);

    return try self.reuse.reuse(self.state, @intCast(first), @intCast(limit));
}

pub fn selectMixedBody(handle: *const anyopaque, first: u64, limit: u64) Action {
    const self = borrow(handle);
    const next = self.ahead.next(self.state, @intCast(first), @intCast(limit), self.keep_skipped) orelse return .Exhausted;

    self.state.owner = next.index;
    self.pending = next;

    return switch (next.action) {
        .Skip => .Skip,
        .MissingSignature => .MissingSignature,
        .AnalyzeZX => .AnalyzeZX,
        .LowerRX => .LowerRX,
    };
}

pub fn rejectMixedBody(handle: *const anyopaque) error{InvalidSourceGraph}!u64 {
    const self = borrow(handle);

    return self.reject(self.pending.index);
}

pub fn analyzeMixedZX(handle: *const anyopaque) State.Error!u64 {
    const self = borrow(handle);

    try self.analyze(self.pending);

    return self.pending.following;
}

pub fn lowerMixedRX(handle: *const anyopaque) State.Error!u64 {
    const self = borrow(handle);

    try self.lower(self.pending);

    return self.pending.following;
}

pub fn skipMixedBody(handle: *const anyopaque) u64 {
    return borrow(handle).pending.following;
}

pub fn recordMixedBody(handle: *const anyopaque) void {
    const self = borrow(handle);
    const next = self.pending;

    self.reuse.analyzed(self.state, next.index, next.position);
}

pub fn materializeMixedModule(handle: *const anyopaque) State.Error!void {
    try borrow(handle).materialize();
}

pub fn publishMixedExports(handle: *const anyopaque) State.Error!void {
    try borrow(handle).publishExports();
}

pub fn retainMixedHistory(handle: *const anyopaque) void {
    const self = borrow(handle);

    self.reuse.finish(self.state, self.selected, self.sources);
}
