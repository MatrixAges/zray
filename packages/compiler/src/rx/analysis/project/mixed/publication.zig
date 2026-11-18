const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Source = @import("frontend").project.artifact.source_link;
const State = @import("state.zig");
const Module = @import("../../module.zig");
const Frame = @import("../history.zig").Frame;

pub const Plan = struct { visible: usize, entry: ?ir.FunctionId };

pub fn entry(table: *const ir.FunctionTable, loaded: *const Source.Loaded, orchestration: bool, exports: bool) Plan {
    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_mixed_entry");

        const input: std.meta.Child(rule.Input) = .{
            .function = if (loaded.function) |id| @backingInt(id) else null,
            .natives = table.native_modules,
            .rx = orchestration,
            .has_exports = exports,
            .has_members = loaded.members.len != 0,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{
            .visible = @intCast(result.visible),
            .entry = if (result.entry) |id| @fromBackingInt(id) else null,
        };
    }

    const count = table.count();
    const id = loaded.function orelse return .{ .visible = count, .entry = null };
    const row = @backingInt(id);
    const visible = if (orchestration and !exports and loaded.members.len == 0) row else count;

    return .{ .visible = visible, .entry = if (row < visible and table.native_modules[row] == null) id else null };
}

pub fn materialize(state: *State, derived: *const Frame, entry_contract: *const ?Module.Contract, exports: bool) State.Error!Module.Contract {
    const dependencies = &derived.dependencies;
    const index = dependencies.entry;
    const root_path = dependencies.modules.items(.path)[index];
    state.owner = index;

    const finished = state.finished.get(index) orelse {
        state.issue = .{ .path = root_path, .location = .{ .offset = 0, .line = 1, .column = 1 }, .code = "module", .message = "entry source module was not compiled" };

        return error.InvalidSourceGraph;
    };

    const table = state.functions.view();
    const plan = entry(&table, &finished, dependencies.sources.at(index) == .rx, exports);
    const functions = table.prefix(plan.visible);

    const program: zx.ir.Program = if (finished.function) |function|
        try @import("function.zig").view(state, function, functions)
    else
        .{ .file_name = root_path, .types = state.types.items.view(), .input_type = finished.input_type, .output_type = finished.output_type, .symbols = .{}, .expressions = .{}, .body = .{}, .functions = functions, .native_modules = state.native_modules.view(), .type_only = true };

    var contract = entry_contract.* orelse Module.Contract{
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

    return contract;
}
