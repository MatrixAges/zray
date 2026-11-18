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
const workflow = @import("workflow/schedule.zig");

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

    const contract = transaction.execute() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSourceGraph => return .{ .diagnostic = state.issue.? },
    };

    return .{ .contract = contract };
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
    fn execute(self: *Transaction) Error!Module.Contract {
        const state = self.state;
        var schedule: Schedule = .{};
        var position: usize = 0;

        bodies: while (position < self.derived.dependencies.order.len) {
            var next: Dispatch = undefined;

            inline for (comptime workflow.steps(.Window)) |step| switch (step) {
                .PrepareWindow => if (schedule.window(self.derived.dependencies.batch_ends, position)) |window| {
                    const consumed = try self.ahead.analyze(state, self.cache, self.sources, self.derived.*, &self.reuse, window, self.arguments);

                    schedule.prepared(consumed);
                },
                .RestorePrefix => position = try self.reuse.reuse(state, position, schedule.first),
                .DispatchBody => {
                    next = self.ahead.next(state, position, schedule.first, self.keep_skipped) orelse {
                        position = schedule.first;

                        continue :bodies;
                    };

                    state.owner = next.index;

                    switch (next.action) {
                        .Skip => {},
                        .MissingSignature => return self.reject(next.index),
                        .AnalyzeZX => try self.analyze(next),
                        .LowerRX => try self.lower(next),
                    }
                },
                .RecordBody => {
                    self.reuse.analyzed(state, next.index, next.position);

                    position = next.following;
                },
                else => unreachable,
            };
        }

        var output: Module.Contract = undefined;

        inline for (comptime workflow.steps(.Finish)) |step| switch (step) {
            .MaterializeOutput => output = try Publication.materialize(state, self.derived, self.entry, self.exports.len != 0),
            .PublishExports => output.exports = try @import("mixed/exports.zig").collect(state, self.exports, self.derived.export_roots),
            .RetainHistory => self.reuse.finish(state, self.selected, self.sources),
            else => unreachable,
        };

        return output;
    }
    fn reject(self: *Transaction, index: usize) Error {
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

        const loaded = if (self.ahead.take(state, next.prepared_row)) |analyzed| linked: {
            _ = state.scratch.reset(.retain_capacity);

            break :linked try module.link(state, analyzed);
        } else try module.compile(state, self.cache, self.sources, index, null);

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
