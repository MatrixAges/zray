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
const Scratch = std.heap.FixedBufferAllocator;

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
    };

    defer transaction.ahead.deinit();

    transaction.execute() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSourceGraph => return .{ .diagnostic = state.issue.? },
    };

    return .{ .contract = transaction.output };
}

pub const Transaction = struct {
    pub const Error = State.Error;
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
    schedule: Schedule = .{},
    position: usize = 0,
    next: Dispatch = undefined,
    entry: ?*@import("mixed/metadata.zig") = null,
    output: Module.Contract = undefined,
    fn execute(self: *Transaction) Error!void {
        if (comptime generated) {
            const entry = @import("generated_rx_mixed_compile");
            var scratch = Scratch.init(&.{});

            return entry.executeIn(scratch.allocator(), @ptrCast(self)) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSource => error.InvalidSourceGraph,
            };
        }

        while (self.active()) {
            try self.prepare();
            if (try self.restore()) continue;

            switch (self.dispatch()) {
                .NextWindow => continue,
                .Skip => {},
                .MissingSignature => try self.reject(),
                .AnalyzeZX => try self.analyze(),
                .LowerRX => try self.lower(),
            }

            self.record();
        }

        try self.materialize();
        try self.publish();

        self.retain();
    }
    pub fn active(self: *const Transaction) bool {
        return self.position < self.derived.dependencies.order.len;
    }

    pub fn prepare(self: *Transaction) Error!void {
        const window = self.schedule.window(self.derived.dependencies.batch_ends, self.position) orelse return;
        const consumed = try self.ahead.analyze(self.state, self.cache, self.sources, self.derived.*, &self.reuse, window, self.arguments);

        self.schedule.prepared(consumed);
    }

    pub fn restore(self: *Transaction) Error!bool {
        self.position = try self.reuse.reuse(self.state, self.position, self.schedule.first);

        return self.position == self.schedule.first;
    }

    pub const Action = enum(u8) { Skip, MissingSignature, AnalyzeZX, LowerRX, NextWindow };

    pub fn dispatch(self: *Transaction) Action {
        self.next = self.ahead.next(self.state, self.position, self.schedule.first, self.keep_skipped);
        self.position = self.next.position;

        if (self.position == self.schedule.first) return .NextWindow;

        self.state.owner = self.next.index;

        return switch (self.next.action) {
            .Skip => .Skip,
            .MissingSignature => .MissingSignature,
            .AnalyzeZX => .AnalyzeZX,
            .LowerRX => .LowerRX,
        };
    }

    pub fn reject(self: *Transaction) Error!void {
        const state = self.state;
        const index = self.next.index;

        state.issue = .{
            .path = state.graph.modules.items(.path)[index],
            .location = .{ .offset = 0, .line = 1, .column = 1 },
            .code = "module",
            .message = "source module signature is missing",
        };

        return error.InvalidSourceGraph;
    }
    pub fn analyze(self: *Transaction) Error!void {
        const state = self.state;
        const index = self.next.index;
        const module = @import("mixed/zx.zig");

        const loaded = if (self.ahead.take(state, self.next.prepared_row)) |analyzed| linked: {
            _ = state.scratch.reset(.retain_capacity);

            break :linked try module.link(state, analyzed);
        } else try module.compile(state, self.cache, self.sources, index, null);

        state.finished.set(index, loaded);
    }
    pub fn lower(self: *Transaction) Error!void {
        const state = self.state;
        const index = self.next.index;
        const derived = self.derived;
        const source = derived.dependencies.sources.at(index).rx;
        const module = @import("mixed/rx.zig");

        const linked = if (self.ahead.lowered(state, self.next.prepared_row)) |lowered| ready: {
            _ = state.scratch.reset(.retain_capacity);

            break :ready try module.link(state, lowered.prepared, lowered.body);
        } else try module.compile(state, self.cache, self.sources, index, derived.loaded.modules[source], derived.resolved.at(source), self.arguments.module(source));

        state.finished.set(index, linked.loaded);

        if (linked.metadata) |metadata| self.entry = metadata;
    }

    pub fn record(self: *Transaction) void {
        self.reuse.analyzed(self.state, self.next.index, self.position);

        self.position += 1;
    }

    pub fn materialize(self: *Transaction) Error!void {
        self.output = try Publication.materialize(self.state, self.derived, self.entry, self.exports.len != 0);
    }

    pub fn publish(self: *Transaction) Error!void {
        self.output.exports = try @import("mixed/exports.zig").collect(self.state, self.exports, self.derived.export_roots);
    }

    pub fn retain(self: *Transaction) void {
        self.reuse.finish(self.state, self.selected, self.sources);
    }
};
