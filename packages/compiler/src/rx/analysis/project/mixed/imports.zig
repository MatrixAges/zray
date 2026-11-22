const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const State = @import("state.zig");
const Edge = @import("../source_graph/model.zig").Edge;
const Binding = std.meta.Child(@FieldType(frontend.ResolvedImports, "imports"));
const Signature = frontend.project.signature_project.Module;
const Selection = frontend.project.import_binding;
const enabled = @import("rx_options").generated_graph and frontend.project.ParseCache.indexed_enabled;
const Indexed = @FieldType(frontend.project.ParseCache.ModuleResult, "indexed");
const Header = if (enabled) @typeInfo(@TypeOf(Indexed.header)).@"fn".return_type.? else void;
pub const Result = struct { functions: []const Binding, published: []const Binding };

pub fn collect(state: *State, allocator: std.mem.Allocator, header: anytype, index: usize, signature: Signature, source_text: []const u8) State.Error!Result {
    const edges = state.graph.modules.items(.dependencies)[index];

    if (edges.len != header.importCount()) return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "source import declarations do not match the dependency graph");

    var bindings: Bindings = .{
        .state = state,
        .allocator = allocator,
        .signature = &signature,
        .edges = edges,
        .source_text = source_text,
    };

    if (comptime enabled and @TypeOf(header) == Header) {
        if (edges.len != 0) try collectIndexed(&bindings, &header);
    } else {
        try collectSeed(&bindings, header);
    }

    return .{
        .functions = if (bindings.functions.items.len == 0) signature.function_imports else bindings.functions.items,
        .published = if (bindings.published.items.len == 0) signature.reexport_functions else bindings.published.items,
    };
}

const Bindings = struct {
    state: *State,
    allocator: std.mem.Allocator,
    signature: *const Signature,
    edges: []const Edge,
    source_text: []const u8,
    functions: std.ArrayList(Binding) = .empty,
    published: std.ArrayList(Binding) = .empty,
    default_member: ?Binding = null,
    members: Selection.Members = undefined,
    selected: Selection.Selection = undefined,
    fn select(self: *Bindings, header: anytype, index: usize) State.Error!usize {
        const state = self.state;
        const edge = self.edges[index];

        const dependency = switch (edge.target) {
            .native => return 0,
            .source => |source| source_block: {
                const loaded = state.finished.get(source) orelse return state.fail(edge.locate(self.source_text), "source function dependency has not been analyzed in its required context");

                break :source_block frontend.project.compiled.Export{ .name = "", .path = "", .function = loaded.function, .types = loaded.exports, .constants = loaded.constant_exports, .members = loaded.members };
            },
            .compiled => |target| try @import("library.zig").load(state, target, edge.location, self.source_text),
        };

        self.default_member = if (dependency.function) |id| own: {
            const row = @backingInt(id);

            break :own .{ .name = "", .id = id, .input_type = @fromBackingInt(state.functions.input_types.items[row]), .output_type = @fromBackingInt(state.functions.output_types.items[row]) };
        } else null;

        self.members = .{ .default = if (self.default_member) |*value| value else null, .named = dependency.members };

        const symbols = Selection.Symbols{ .target = if (edge.target == .source) .source else .compiled, .types = state.types.items.view(), .exports = dependency.types, .constants = dependency.constants, .functions = self.members.names() };
        const view = frontend.project.import_view.get(header, index);
        var reporter: zx.Reporter = .{};

        self.selected = Selection.select(state.scratch.allocator(), state.allocator, view, &symbols, &reporter) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return state.fail(edge.locate(self.source_text), reporter.diagnostic.?.message);
        };

        return self.selected.functions.names.len;
    }
    fn destination(self: *Bindings, exported: bool) *std.ArrayList(Binding) {
        return if (exported) &self.published else &self.functions;
    }
    fn reserve(self: *Bindings, exported: bool, count: usize, include_prefix: bool) std.mem.Allocator.Error!void {
        const prefix = if (!include_prefix) &.{} else if (exported) self.signature.reexport_functions else self.signature.function_imports;
        const target = self.destination(exported);
        const total = std.math.add(usize, prefix.len, count) catch return error.OutOfMemory;

        try target.ensureUnusedCapacity(self.allocator, total);

        target.appendSliceAssumeCapacity(prefix);
    }
    fn append(self: *Bindings, exported: bool, row: usize) std.mem.Allocator.Error!void {
        const functions = self.selected.functions;
        var member = self.members.at(@intCast(functions.indices[row])).*;

        member.name = try self.allocator.dupe(u8, functions.names[row]);

        self.destination(exported).appendAssumeCapacity(member);
    }
};

const Frame = struct {
    bindings: *Bindings,
    header: *const Header,
    fn borrow(handle: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(handle));
    }
};

fn collectIndexed(bindings: *Bindings, header: *const Header) State.Error!void {
    const rule = @import("generated_rx_mixed_import_bindings");
    const Input = std.meta.Child(rule.Input);
    const frame: Frame = .{ .bindings = bindings, .header = header };

    const input: Input = .{
        .binding = @ptrCast(&frame),
        .imports = zx.columns.slice(@FieldType(Input, "imports"), header.storage.imports),
    };

    return @import("body.zig").run(rule, &input);
}

pub fn selectMixedImport(handle: *const anyopaque, row: u64) State.Error!u64 {
    const frame = Frame.borrow(handle);

    return try frame.bindings.select(frame.header.*, @intCast(row));
}

pub fn reserveMixedImportBindings(handle: *const anyopaque, exported: bool, count: u64, include_prefix: bool) std.mem.Allocator.Error!void {
    try Frame.borrow(handle).bindings.reserve(exported, @intCast(count), include_prefix);
}

pub fn appendMixedImportBinding(handle: *const anyopaque, exported: bool, row: u64) std.mem.Allocator.Error!void {
    try Frame.borrow(handle).bindings.append(exported, @intCast(row));
}

fn collectSeed(bindings: *Bindings, header: anytype) State.Error!void {
    for (0..header.importCount()) |row| {
        const item = header.importAt(row);

        if (item.kind == .type_only) continue;

        const count = try bindings.select(header, row);

        if (count == 0) continue;
        try bindings.reserve(item.exported, count, bindings.destination(item.exported).items.len == 0);
        for (0..count) |index| try bindings.append(item.exported, index);
    }
}
