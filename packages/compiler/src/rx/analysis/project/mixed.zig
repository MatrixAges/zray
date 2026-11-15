const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Module = @import("../module.zig");
const Frame = @import("history.zig").Frame;
const State = @import("mixed/state.zig");
const Inputs = @import("call_inputs.zig");
const Schedule = @import("mixed/schedule.zig");

/// Analyzes and links every module in dependency order over the shared tables `derived` starts them from.
pub fn compile(allocator: std.mem.Allocator, backing: std.mem.Allocator, derived: Frame, selected: []const rx.ModuleSource, sources: []const frontend.project.Source, exports: []const @import("../project.zig").Export, cache: *frontend.project.ParseCache, record: ?*@import("history.zig").History, arguments: *const Inputs) std.mem.Allocator.Error!Module.Value {
    const dependencies = derived.dependencies;
    const loaded = derived.loaded;
    const resolved = derived.resolved;

    var state = State.init(allocator, backing, dependencies, derived.signatures, derived.signature_indices, derived.types, loaded.project) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = .{ .path = dependencies.modules.items(.path)[dependencies.entry], .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "contract", .message = "source signatures cannot initialize the shared compilation context" } };
    };

    defer state.scratch.deinit();

    var entry: ?Module.Contract = null;
    var reuse = try @import("mixed/reuse.zig").begin(&state, cache, record, derived, sources);
    var ahead: @import("mixed/ahead.zig") = .{};

    defer ahead.deinit();

    var schedule: Schedule = .{};
    var position: usize = 0;

    while (position < dependencies.order.len) {
        if (schedule.window(dependencies.batch_ends, position)) |window| {
            schedule.prepared(try ahead.analyze(&state, cache, sources, derived, &reuse, window, arguments));
        }

        position = try reuse.reuse(&state, position, schedule.first);

        if (position == schedule.first) continue;

        const next = ahead.next(&state, position, schedule.first, record != null);

        position = next.position;

        if (position == schedule.first) continue;

        const index = next.index;

        state.owner = index;

        switch (next.action) {
            .Skip => {},
            .MissingSignature => return .{ .diagnostic = .{ .path = dependencies.modules.items(.path)[index], .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "module", .message = "source module signature is missing" } },
            .AnalyzeZX => {
                const zx_module = @import("mixed/zx.zig");

                const body = if (ahead.take(&state, next.prepared_row)) |analyzed| linked: {
                    _ = state.scratch.reset(.retain_capacity);

                    break :linked zx_module.link(&state, state.scratch.allocator(), analyzed);
                } else zx_module.compile(&state, cache, sources, index, null);

                const linked = body catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return .{ .diagnostic = state.issue.? };
                };

                state.finished.set(index, linked);
            },
            .LowerRX => {
                const source = dependencies.sources.at(index).rx;
                const rx_module = @import("mixed/rx.zig");

                const linked = if (ahead.lowered(&state, next.prepared_row)) |lowered| ready: {
                    _ = state.scratch.reset(.retain_capacity);

                    break :ready rx_module.link(&state, state.scratch.allocator(), lowered.prepared, lowered.contract);
                } else rx_module.compile(&state, cache, sources, index, loaded.modules[source], resolved[source], arguments.module(source));

                const result = linked catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return .{ .diagnostic = state.issue.? };
                };

                state.finished.set(index, result.loaded);

                if (index == dependencies.entry) entry = result.contract;
            },
        }

        reuse.analyzed(&state, index, position);

        position += 1;
    }

    state.owner = dependencies.entry;

    const root_path = dependencies.modules.items(.path)[dependencies.entry];
    const finished = state.finished.get(dependencies.entry) orelse return .{ .diagnostic = .{ .path = root_path, .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "module", .message = "entry source module was not compiled" } };
    const table = state.functions.view();
    const publication = @import("mixed/publication.zig").entry(&table, &finished, dependencies.sources.at(dependencies.entry) == .rx, exports.len != 0);
    const functions = table.prefix(publication.visible);

    const program = if (finished.function) |function|
        @import("mixed/function.zig").view(&state, function, functions) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return .{ .diagnostic = state.issue.? };
        }

    else
        zx.ir.Program{ .file_name = root_path, .types = state.types.items.view(), .input_type = finished.input_type, .output_type = finished.output_type, .symbols = .{}, .expressions = .{}, .body = .{}, .functions = functions, .native_modules = state.native_modules.view(), .type_only = true };

    var contract = entry orelse Module.Contract{
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
    contract.entry_function = publication.entry;
    contract.public_functions = finished.members;
    contract.store_initializers = state.initializers.items;
    contract.types = state.types.items.view();
    contract.native_modules = state.native_modules.view();
    contract.nominal_types = state.types.origins.items.view();
    contract.input_type = contract.program.input_type;
    contract.output_type = contract.program.output_type;

    contract.exports = @import("mixed/exports.zig").collect(&state, exports, derived.export_roots) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = state.issue.? };
    };

    reuse.finish(&state, selected, sources);

    return .{ .contract = contract };
}
