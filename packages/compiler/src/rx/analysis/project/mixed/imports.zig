const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const memory = zx.memory;
const State = @import("state.zig");
const Edge = @import("../source_graph/model.zig").Edge;
const Binding = std.meta.Child(@FieldType(frontend.ResolvedImports, "imports"));
const Signature = frontend.project.signature_project.Module;
const Selection = frontend.project.import_binding;
const enabled = @import("rx_options").generated_graph and frontend.project.ParseCache.indexed_enabled;
const Indexed = @FieldType(frontend.project.ParseCache.ModuleResult, "indexed");
const Header = if (enabled) @typeInfo(@TypeOf(Indexed.header)).@"fn".return_type.? else void;
const Selected = if (enabled) @import("rx_execution_abi").layouts.@"zig:rx_project_host".MixedImportSelection else void;
pub const Result = struct { functions: []const Binding, published: []const Binding };

pub fn collect(state: *State, allocator: std.mem.Allocator, header: anytype, index: usize, signature: *const Signature, source_text: []const u8) State.Error!Result {
    const edges = state.graph.modules.items(.dependencies)[index];

    if (edges.len != header.importCount()) return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "source import declarations do not match the dependency graph");

    var bindings: Bindings = .{
        .state = state,
        .allocator = allocator,
        .signature = signature,
        .edges = edges,
        .source_text = source_text,
    };

    if (comptime enabled and @TypeOf(header) == Header) {
        if (edges.len == 0) return .{ .functions = signature.function_imports, .published = signature.reexport_functions };

        return collectIndexed(&bindings, &header);
    }

    try collectSeed(&bindings, header);

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

        const function, const types, const constants, const members = switch (edge.target) {
            .native => return 0,
            .source => |source| source_block: {
                const loaded = state.finished.get(source) orelse return state.fail(edge.locate(self.source_text), "source function dependency has not been analyzed in its required context");

                break :source_block .{ state.finished.function(source), loaded.exports, loaded.constant_exports, loaded.members };
            },
            .compiled => |target| compiled_block: {
                const loaded = try @import("library.zig").load(state, target, edge.location, self.source_text);

                break :compiled_block .{ loaded.function, loaded.types, loaded.constants, loaded.members };
            },
        };

        self.default_member = if (function) |id| own: {
            const row = @backingInt(id);

            break :own .{ .name = "", .id = id, .input_type = @fromBackingInt(state.functions.input_types.items[row]), .output_type = @fromBackingInt(state.functions.output_types.items[row]) };
        } else null;

        self.members = .{ .default = if (self.default_member) |*value| value else null, .named = members };

        const symbols = Selection.Symbols{ .target = if (edge.target == .source) .source else .compiled, .types = state.types.items.view(), .exports = types, .constants = constants, .functions = self.members.names() };
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
    selected: Selected = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

fn collectIndexed(bindings: *Bindings, header: *const Header) State.Error!Result {
    const rule = @import("generated_rx_mixed_import_bindings");
    const Input = std.meta.Child(rule.Input);
    const signature = bindings.signature;
    var frame: Frame = .{ .bindings = bindings, .header = header };
    var functions = memory.RowBuffer.empty(Binding);
    var published = memory.RowBuffer.empty(Binding);
    var used = [_]u64{ 0, 0 };
    const function_used: []u64 = used[0..1];
    const published_used: []u64 = used[1..2];

    const input: Input = .{
        .binding = @ptrCast(&frame),
        .imports = zx.columns.slice(@FieldType(Input, "imports"), header.storage.imports),
        .functions = &.{
            .storage = @ptrCast(&functions),
            .bytes = @ptrCast(&functions.bytes),
            .prefix = std.mem.sliceAsBytes(signature.function_imports),
            .used = @ptrCast(&function_used),
        },
        .published = &.{
            .storage = @ptrCast(&published),
            .bytes = @ptrCast(&published.bytes),
            .prefix = std.mem.sliceAsBytes(signature.reexport_functions),
            .used = @ptrCast(&published_used),
        },
        .layout = &.{ .stride = @sizeOf(Binding), .name_offset = @offsetOf(Binding, "name") },
    };

    rule.executeIn(bindings.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSourceGraph => return error.InvalidSourceGraph,
        else => unreachable,
    };

    return .{
        .functions = if (used[0] == 0) signature.function_imports else functions.rows(Binding)[0..@intCast(used[0])],
        .published = if (used[1] == 0) signature.reexport_functions else published.rows(Binding)[0..@intCast(used[1])],
    };
}

pub fn selectMixedImport(handle: *const anyopaque, row: u64) State.Error!?*const Selected {
    const frame = Frame.borrow(handle);
    const bindings = frame.bindings;

    if (try bindings.select(frame.header.*, @intCast(row)) == 0) return null;

    frame.selected = .{
        .names = bindings.selected.functions.names,
        .indices = bindings.selected.functions.indices,
        .named = std.mem.sliceAsBytes(bindings.members.named),
        .fallback = if (bindings.members.default) |member| std.mem.asBytes(member) else &.{},
    };

    return &frame.selected;
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
