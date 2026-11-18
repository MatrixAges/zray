const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Source = @import("frontend").project.artifact.source_link;
const State = @import("state.zig");
const Module = @import("../../module.zig");
const Frame = @import("../history.zig").Frame;
const Metadata = @import("metadata.zig");
const generated = @import("rx_options").generated_graph;
const Form = if (generated) @FieldType(std.meta.Child(@import("generated_rx_mixed_entry").Output), "form") else enum { Missing, InvalidFunction, TypeOnly, Function };
const Plan = struct { form: Form, visible: usize = 0, entry: ?ir.FunctionId = null };

fn entry(table: *const ir.FunctionTable, loaded: ?Source.Loaded, orchestration: bool, exports: bool) Plan {
    const function = if (loaded) |value| value.function else null;
    const members = if (loaded) |value| value.members.len != 0 else false;

    if (comptime generated) {
        const rule = @import("generated_rx_mixed_entry");

        const input: std.meta.Child(rule.Input) = .{
            .present = loaded != null,
            .function = if (function) |id| @backingInt(id) else null,
            .natives = table.native_modules,
            .rx = orchestration,
            .has_exports = exports,
            .has_members = members,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{
            .form = result.form,
            .visible = @intCast(result.visible),
            .entry = if (result.entry) |id| @fromBackingInt(id) else null,
        };
    }

    if (loaded == null) return .{ .form = .Missing };

    const count = table.count();
    const id = function orelse return .{ .form = .TypeOnly, .visible = count };
    const row = @backingInt(id);

    if (row >= count) return .{ .form = .InvalidFunction };

    const visible = if (orchestration and !exports and !members) row else count;

    return .{ .form = .Function, .visible = visible, .entry = if (row < visible and table.native_modules[row] == null) id else null };
}

pub fn materialize(state: *State, derived: *const Frame, metadata: ?*Metadata, exports: bool) State.Error!Module.Contract {
    const dependencies = &derived.dependencies;
    const index = dependencies.entry;
    state.owner = index;

    const finished = state.finished.get(index);
    const table = state.functions.view();
    const plan = entry(&table, finished, dependencies.sources.at(index) == .rx, exports);
    const functions = table.prefix(plan.visible);
    const types = state.types.items.view();
    const natives = state.native_modules.view();
    const location = @import("rx").ast.Location{ .offset = 0, .line = 1, .column = 1 };

    var program: ir.Program = switch (plan.form) {
        .Missing => return state.fail(location, "entry source module was not compiled"),
        .InvalidFunction => return state.fail(location, "resolved function is outside the shared function table"),
        .Function => body: {
            const id = finished.?.function.?;

            break :body try @import("function.zig").programView(state.allocator, table.get(id), id, functions, types, natives);
        },
        .TypeOnly => .{
            .file_name = dependencies.modules.items(.path)[index],
            .types = types,
            .input_type = finished.?.input_type,
            .output_type = finished.?.output_type,
            .symbols = .{},
            .expressions = .{},
            .body = .{},
            .functions = functions,
            .native_modules = natives,
            .type_only = true,
        },
    };

    const loaded = &finished.?;

    program.exports = loaded.exports;
    program.constant_exports = loaded.constant_exports;

    if (metadata) |observed| try observed.publish(state);

    return .{
        .program = program,
        .types = types,
        .native_modules = natives,
        .nominal_types = state.types.origins.items.view(),
        .input_type = program.input_type,
        .output_type = program.output_type,
        .entry_function = plan.entry,
        .public_functions = loaded.members,
        .store_initializers = state.initializers.items,
        .calls = if (metadata) |observed| observed.calls else &.{},
        .result = if (metadata) |observed| observed.result else null,
    };
}
