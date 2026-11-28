const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Module = @import("../module.zig");
const Frame = @import("history.zig").Frame;
const State = @import("mixed/state.zig");
const Inputs = @import("call_inputs.zig");
const Schedule = @import("mixed/schedule.zig");
const Ahead = @import("mixed/ahead.zig");
const Rx = @import("mixed/rx.zig");
const Zx = @import("mixed/zx.zig");
const Reuse = @import("mixed/reuse.zig");
const Publication = @import("mixed/publication.zig");
const Dispatch = @import("mixed/schedule/dispatch.zig").Result;
const Export = @import("../project.zig").Export;
const generated = @import("rx_options").generated_graph;

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
    output: *Module.Contract,
    fn execute(self: *Transaction) Error!void {
        if (comptime generated) {
            const entry = @import("generated_rx_execute_mixed");
            const batch_ends = @import("history/columns.zig").words(std.mem.sliceAsBytes(self.derived.dependencies.batch_ends));

            const input: std.meta.Child(entry.Input) = .{
                .batch_ends = @ptrCast(&batch_ends),
                .length = self.derived.dependencies.order.len,
                .has_exports = self.exports.len != 0,
                .retain = self.keep_skipped,
            };

            const Store = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

            var snapshot: std.meta.Child(Store) = .{
                .step = .Select,
                .first = null,
                .end = null,
                .row = null,
                .selection = null,
                .action = .Exhausted,
                .index = 0,
                .position = 0,
                .following = 0,
                .prepared_row = null,
                .count = 0,
                .prepared = null,
                .accepted = false,
            };

            var store: Store = &snapshot;

            const Host = struct {
                transaction: *Transaction,
                snapshot: *std.meta.Child(Store),
                store_0: *Store,
                pub fn commit(host: *@This(), pending: anytype) Error!void {
                    const effect = pending.store_0 orelse return;
                    const current = host.transaction;
                    const state = current.state;

                    switch (effect.step) {
                        .Prefetch => host.snapshot.count = try current.prefetch(.{ .first = @intCast(effect.first.?), .end = @intCast(effect.end.?) }),
                        .RestorePrefix => host.snapshot.count = try current.reuse.reuse(state, @intCast(effect.first.?), @intCast(effect.end.?)),
                        .Select => {
                            const next = current.ahead.next(state, @intCast(effect.first.?), @intCast(effect.end.?), current.keep_skipped);

                            host.snapshot.action = .Exhausted;

                            if (next) |selected| {
                                const Action = @FieldType(std.meta.Child(Store), "action");
                                state.owner = selected.index;

                                host.snapshot.action = switch (selected.action) {
                                    inline else => |tag| @field(Action, @tagName(tag)),
                                };
                                host.snapshot.index = selected.index;
                                host.snapshot.position = selected.position;
                                host.snapshot.following = selected.following;
                                host.snapshot.prepared_row = selected.prepared_row;
                            }
                        },
                        .Reject => return current.reject(@intCast(effect.selection.?.index)),
                        .PreparedZX => host.snapshot.prepared = current.ahead.zxRow(if (effect.row) |row| @intCast(row) else null),
                        .AcceptZX => host.snapshot.accepted = current.ahead.acceptsZX(state, @intCast(effect.row.?)),
                        .RetireZX => current.ahead.retireZX(@intCast(effect.row.?)),
                        .LinkZX => try current.ahead.linkZX(state, @intCast(effect.row.?), @intCast(effect.selection.?.index)),
                        .AnalyzeZX => try current.analyzeAtTurn(@intCast(effect.selection.?.index)),
                        .AcceptedRX => host.snapshot.prepared = current.ahead.acceptedRX(state, if (effect.row) |row| @intCast(row) else null),
                        .LinkRX => if (try current.ahead.linkRX(state, @intCast(effect.row.?))) |metadata| {
                            current.entry = metadata;
                        },
                        .LowerRX => try current.lowerAtTurn(@intCast(effect.selection.?.index)),
                        .Record => {
                            const selected = effect.selection.?;

                            try current.reuse.analyzed(state, @intCast(selected.index), @intCast(selected.position));
                        },
                        .Materialize => try current.materialize(),
                        .Observations => try current.publishObservations(),
                        .Exports => try current.publishExports(),
                        .Retain => current.reuse.finish(state, current.selected, current.sources),
                    }
                }
            };

            var host: Host = .{ .transaction = self, .snapshot = &snapshot, .store_0 = &store };

            return @import("mixed/body.zig").run(entry, self.state.scratch.child_allocator, &input, &host);
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
                .AnalyzeZX => if (!try self.linkPreparedZX(next)) try self.analyzeAtTurn(next.index),
                .LowerRX => if (!try self.linkPreparedRX(next)) try self.lowerAtTurn(next.index),
            }

            try self.reuse.analyzed(state, next.index, next.position);

            position = next.following;
        }

        try self.materialize();
        try self.publishObservations();
        try self.publishExports();

        self.reuse.finish(state, self.selected, self.sources);
    }

    fn prefetch(self: *Transaction, window: Schedule.Window) std.mem.Allocator.Error!usize {
        const consumed = try self.ahead.analyze(self.state, self.cache, self.sources, self.derived.*, &self.reuse, window, self.arguments);

        std.debug.assert(consumed != 0 and consumed <= window.end - window.first);

        return consumed;
    }
    fn materialize(self: *Transaction) Error!void {
        try Publication.materialize(self.state, self.output, self.exports.len != 0);
    }
    fn publishObservations(self: *Transaction) std.mem.Allocator.Error!void {
        const observed = self.entry orelse return;

        try observed.publish(self.state);

        self.output.calls = observed.calls;
        self.output.result = observed.result;
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
    fn linkPreparedZX(self: *Transaction, next: Dispatch) Error!bool {
        const row = self.ahead.zxRow(next.prepared_row) orelse return false;

        if (!self.ahead.acceptsZX(self.state, row)) {
            self.ahead.retireZX(row);

            return false;
        }

        try self.ahead.linkZX(self.state, row, next.index);

        return true;
    }
    fn analyzeAtTurn(self: *Transaction, index: usize) Error!void {
        const state = self.state;

        try Zx.compile(state, self.cache, self.sources, index, null, state.finished.destination(index));
    }

    fn linkPreparedRX(self: *Transaction, next: Dispatch) Error!bool {
        const row = self.ahead.acceptedRX(self.state, next.prepared_row) orelse return false;

        if (try self.ahead.linkRX(self.state, row)) |metadata| self.entry = metadata;

        return true;
    }
    fn lowerAtTurn(self: *Transaction, index: usize) Error!void {
        const derived = self.derived;
        const source = derived.dependencies.sources.at(index).rx;
        const metadata = try Rx.compile(self.state, self.cache, self.sources, index, derived.loaded.modules[source], derived.resolved.at(source), self.arguments.module(source));

        if (metadata) |entry| self.entry = entry;
    }
};
