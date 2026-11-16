const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Module = @import("../module.zig");
const Frame = @import("history.zig").Frame;
const State = @import("mixed/state.zig");
const Inputs = @import("call_inputs.zig");
const Schedule = @import("mixed/schedule.zig");
const Stages = @import("mixed/compile/steps.zig");
const Ahead = @import("mixed/ahead.zig");
const Reuse = @import("mixed/reuse.zig");
const Publication = @import("mixed/publication.zig");
const Loaded = frontend.project.artifact.source_link.Loaded;
const Dispatch = @import("mixed/schedule/dispatch.zig").Result;
const Export = @import("../project.zig").Export;

/// Analyzes and links every module in dependency order over the shared tables `derived` starts them from.
pub fn compile(allocator: std.mem.Allocator, backing: std.mem.Allocator, derived: Frame, selected: []const rx.ModuleSource, sources: []const frontend.project.Source, exports: []const Export, cache: *frontend.project.ParseCache, record: ?*@import("history.zig").History, arguments: *const Inputs) std.mem.Allocator.Error!Module.Value {
    const dependencies = derived.dependencies;
    const loaded = derived.loaded;

    var state = State.init(allocator, backing, dependencies, derived.signatures, derived.signature_indices, derived.types, loaded.project) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = .{ .path = dependencies.modules.items(.path)[dependencies.entry], .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "contract", .message = "source signatures cannot initialize the shared compilation context" } };
    };

    defer state.scratch.deinit();

    var entry: ?Module.Contract = null;
    var reuse = try Reuse.begin(&state, cache, record, derived, sources);
    var ahead: Ahead = .{};

    defer ahead.deinit();

    var schedule: Schedule = .{};
    var position: usize = 0;

    windows: while (position < dependencies.order.len) {
        var next: Dispatch = undefined;

        inline for (comptime Stages.steps(.Window)) |step| {
            switch (step) {
                .PrepareWindow => if (schedule.window(dependencies.batch_ends, position)) |window| {
                    schedule.prepared(try ahead.analyze(&state, cache, sources, derived, &reuse, window, arguments));
                },
                .RestorePrefix => {
                    position = try reuse.reuse(&state, position, schedule.first);

                    if (position == schedule.first) continue :windows;
                },
                .NextBody => {
                    next = ahead.next(&state, position, schedule.first, record != null);
                    position = next.position;

                    if (position == schedule.first) continue :windows;
                },
                .LinkBody => {
                    linkBody(&state, &ahead, &derived, cache, sources, arguments, next, &entry) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;

                        return .{ .diagnostic = state.issue.? };
                    };
                },
                .RecordBoundary => {
                    reuse.analyzed(&state, next.index, position);

                    position += 1;
                },
                else => unreachable,
            }
        }
    }

    return publish(&state, &reuse, &derived, &entry, selected, sources, exports);
}

inline fn linkBody(state: *State, ahead: *const Ahead, derived: *const Frame, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, arguments: *const Inputs, next: Dispatch, entry: *?Module.Contract) State.Error!void {
    const index = next.index;

    state.owner = index;

    switch (next.action) {
        .Skip => {},
        .MissingSignature => {
            state.issue = .{
                .path = state.graph.modules.items(.path)[index],
                .location = .{ .offset = 0, .line = 1, .column = 1 },
                .code = "module",
                .message = "source module signature is missing",
            };

            return error.InvalidSourceGraph;
        },
        .AnalyzeZX => {
            const module = @import("mixed/zx.zig");

            const loaded = if (ahead.take(state, next.prepared_row)) |analyzed| linked: {
                _ = state.scratch.reset(.retain_capacity);

                break :linked try module.link(state, analyzed);
            } else try module.compile(state, cache, sources, index, null);

            state.finished.set(index, loaded);
        },
        .LowerRX => {
            const source = derived.dependencies.sources.at(index).rx;
            const module = @import("mixed/rx.zig");

            const linked = if (ahead.lowered(state, next.prepared_row)) |lowered| ready: {
                _ = state.scratch.reset(.retain_capacity);

                break :ready try module.link(state, lowered.prepared, lowered.contract);
            } else try module.compile(state, cache, sources, index, derived.loaded.modules[source], derived.resolved[source], arguments.module(source));

            state.finished.set(index, linked.loaded);

            if (index == derived.dependencies.entry) entry.* = linked.contract;
        },
    }
}

fn publish(state: *State, reuse: *const Reuse, derived: *const Frame, entry: *const ?Module.Contract, selected: []const rx.ModuleSource, sources: []const frontend.project.Source, exports: []const Export) std.mem.Allocator.Error!Module.Value {
    const dependencies = &derived.dependencies;
    const root_path = dependencies.modules.items(.path)[dependencies.entry];
    var finished: Loaded = undefined;
    var plan: Publication.Plan = undefined;
    var program: zx.ir.Program = undefined;
    var contract: Module.Contract = undefined;

    inline for (comptime Stages.steps(.Output)) |step| {
        switch (step) {
            .ResolveEntry => {
                state.owner = dependencies.entry;
                finished = state.finished.get(dependencies.entry) orelse return .{ .diagnostic = .{ .path = root_path, .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "module", .message = "entry source module was not compiled" } };
            },
            .BuildEntryProgram => {
                const table = state.functions.view();

                plan = Publication.entry(&table, &finished, dependencies.sources.at(dependencies.entry) == .rx, exports.len != 0);
                const functions = table.prefix(plan.visible);

                program = if (finished.function) |function|
                    @import("mixed/function.zig").view(state, function, functions) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;

                        return .{ .diagnostic = state.issue.? };
                    }

                else
                    .{ .file_name = root_path, .types = state.types.items.view(), .input_type = finished.input_type, .output_type = finished.output_type, .symbols = .{}, .expressions = .{}, .body = .{}, .functions = functions, .native_modules = state.native_modules.view(), .type_only = true };
            },
            .PublishContract => {
                contract = entry.* orelse .{
                    .program = program,
                    .types = state.types.items.view(),
                    .nominal_types = state.types.origins.items.view(),
                    .input_type = program.input_type,
                    .output_type = program.output_type,
                    .calls = &.{},
                    .result = null,
                    .native_modules = state.native_modules.view(),
                };

                contract.program = program;
                contract.program.exports = finished.exports;
                contract.program.constant_exports = finished.constant_exports;
                contract.entry_function = plan.entry;
                contract.public_functions = finished.members;
                contract.store_initializers = state.initializers.items;
                contract.types = state.types.items.view();
                contract.native_modules = state.native_modules.view();
                contract.nominal_types = state.types.origins.items.view();
                contract.input_type = program.input_type;
                contract.output_type = program.output_type;
            },
            .PublishExports => contract.exports = @import("mixed/exports.zig").collect(state, exports, derived.export_roots) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                return .{ .diagnostic = state.issue.? };
            },
            .RetainHistory => reuse.finish(state, selected, sources),
            else => unreachable,
        }
    }

    return .{ .contract = contract };
}
