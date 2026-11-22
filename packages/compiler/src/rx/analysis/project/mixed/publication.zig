const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Source = @import("frontend").project.artifact.source_link;
const State = @import("state.zig");
const Module = @import("../../module.zig");
const generated = @import("rx_options").generated_graph;

pub fn materialize(state: *State, output: *Module.Contract, exports: bool) State.Error!void {
    const index = state.graph.entry;
    state.owner = index;

    const table = state.functions.view();
    const frame: Entry = .{ .state = state, .output = output, .table = &table, .loaded = state.finished.get(index) };
    const function = if (frame.loaded) |loaded| loaded.function else null;
    const members = if (frame.loaded) |loaded| loaded.members.len != 0 else false;
    const orchestration = state.graph.sources.at(index) == .rx;

    if (comptime generated) {
        const rule = @import("generated_rx_mixed_entry");

        const input: std.meta.Child(rule.Input) = .{
            .target = @ptrCast(&frame),
            .present = frame.loaded != null,
            .function = if (function) |id| @backingInt(id) else null,
            .natives = table.native_modules,
            .rx = orchestration,
            .has_exports = exports,
            .has_members = members,
        };

        return @import("body.zig").run(rule, &input);
    }

    if (frame.loaded == null) return frame.reject("entry source module was not compiled");

    const count = table.count();
    const id = function orelse return frame.installType(count);
    const row = @backingInt(id);

    if (row >= count) return frame.reject("resolved function is outside the shared function table");

    const visible = if (orchestration and !exports and !members) row else count;
    const entry = if (row < visible and table.native_modules[row] == null) id else null;

    try frame.installFunction(id, visible, entry);
}

const Entry = struct {
    state: *State,
    output: *Module.Contract,
    table: *const ir.FunctionTable,
    loaded: ?Source.Loaded,
    fn borrow(handle: *const anyopaque) *const Entry {
        return @ptrCast(@alignCast(handle));
    }
    fn installType(self: *const Entry, visible: usize) void {
        const state = self.state;
        const loaded = self.loaded.?;

        var program: ir.Program = .{
            .file_name = state.graph.modules.items(.path)[state.owner],
            .types = state.types.items.view(),
            .input_type = loaded.input_type,
            .output_type = loaded.output_type,
            .symbols = .{},
            .expressions = .{},
            .body = .{},
            .functions = self.table.prefix(visible),
            .native_modules = state.native_modules.view(),
            .type_only = true,
        };

        self.install(&program, null);
    }
    fn installFunction(self: *const Entry, id: ir.FunctionId, visible: usize, entry: ?ir.FunctionId) std.mem.Allocator.Error!void {
        const state = self.state;

        var program = try @import("function.zig").programView(
            state.allocator,
            self.table.get(id),
            id,
            self.table.prefix(visible),
            state.types.items.view(),
            state.native_modules.view(),
        );

        self.install(&program, entry);
    }
    fn install(self: *const Entry, program: *ir.Program, entry: ?ir.FunctionId) void {
        const state = self.state;
        const loaded = &self.loaded.?;

        program.exports = loaded.exports;
        program.constant_exports = loaded.constant_exports;

        self.output.* = .{
            .program = program.*,
            .types = program.types,
            .native_modules = program.native_modules,
            .nominal_types = state.types.origins.items.view(),
            .input_type = program.input_type,
            .output_type = program.output_type,
            .entry_function = entry,
            .public_functions = loaded.members,
            .store_initializers = state.initializers.items,
            .calls = &.{},
            .result = null,
        };
    }
    fn reject(self: *const Entry, message: []const u8) State.Error {
        return self.state.fail(.{ .offset = 0, .line = 1, .column = 1 }, message);
    }
};

pub fn installMixedTypeEntry(handle: *const anyopaque, visible: u64) void {
    Entry.borrow(handle).installType(@intCast(visible));
}

pub fn installMixedFunctionEntry(handle: *const anyopaque, function: u32, visible: u64, entry: ?u32) std.mem.Allocator.Error!void {
    try Entry.borrow(handle).installFunction(@fromBackingInt(function), @intCast(visible), if (entry) |id| @fromBackingInt(id) else null);
}

pub fn rejectMixedEntry(handle: *const anyopaque, message: []const u8) State.Error!void {
    return Entry.borrow(handle).reject(message);
}
