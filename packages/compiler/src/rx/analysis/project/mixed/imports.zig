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
const Parse = frontend.project.ParseCache.ModuleResult;
const rule = if (enabled) @import("generated_rx_mixed_import_bindings") else void;
const Input = if (enabled) std.meta.Child(rule.Input) else void;
const Rows = if (enabled) @import("rx_execution_abi").layouts.@"zig:rx_project_host".MixedImportRows else void;

pub const Result = struct { functions: []const Binding, published: []const Binding };

pub fn collect(state: *State, allocator: std.mem.Allocator, parsed: *const Parse, index: usize, signature: *const Signature, source_text: []const u8) State.Error!Result {
    const edges = state.graph.modules.items(.dependencies)[index];

    const count = switch (parsed.*) {
        .native => |parsed_source| nativeHeader(parsed_source).importCount(),
        .indexed => |*indexed| if (comptime enabled) indexed.header().importCount() else unreachable,
    };

    if (edges.len != count) return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "source import declarations do not match the dependency graph");
    if (count == 0) return .{ .functions = signature.function_imports, .published = signature.reexport_functions };

    var bindings: Bindings = .{
        .state = state,
        .parsed = parsed,
        .edges = edges,
        .source_text = source_text,
    };

    if (comptime enabled) return collectSource(&bindings, allocator, signature);

    return collectSeed(&bindings, allocator, signature);
}

const Bindings = struct {
    state: *State,
    parsed: *const Parse,
    edges: []const Edge,
    source_text: []const u8,
    default_member: ?Binding = null,
    members: Selection.Members = undefined,
    request: if (enabled) Selection.Request.Storage else void = undefined,
    rows: Rows = undefined,
    fn borrow(handle: *const anyopaque) *Bindings {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn dependency(self: *Bindings, index: usize) State.Error!?Selection.Symbols {
        const state = self.state;
        const edge = self.edges[index];

        const function, const types, const constants, const members = switch (edge.target) {
            .native => return null,
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

        return .{ .target = if (edge.target == .source) .source else .compiled, .types = state.types.items.view(), .exports = types, .constants = constants, .functions = self.members.names() };
    }
    fn reject(self: *Bindings, row: usize, message: []const u8) State.Error {
        return self.state.fail(self.edges[row].locate(self.source_text), message);
    }
    fn open(self: *Bindings, header: anytype, row: usize) State.Error!?*const Rows {
        const item = frontend.project.import_view.get(header, row);

        if (item.kind == .type_only) return null;

        const symbols = try self.dependency(row) orelse return null;

        _ = self.request.init(item, &symbols);

        self.rows = .{
            .named = std.mem.sliceAsBytes(self.members.named),
            .fallback = if (self.members.default) |member| std.mem.asBytes(member) else &.{},
            .exported = item.exported,
        };

        return &self.rows;
    }
};

fn collectSource(bindings: *Bindings, allocator: std.mem.Allocator, signature: *const Signature) State.Error!Result {
    const scratch = bindings.state.scratch.allocator();
    var scope: memory.ArenaScope = .{ .active = scratch };
    var functions = memory.RowBuffer.empty(Binding);
    var published = memory.RowBuffer.empty(Binding);
    var used = [_]u64{ 0, 0 };
    const function_used: []u64 = used[0..1];
    const published_used: []u64 = used[1..2];
    const symbols: *const @TypeOf(bindings.request.input) = &bindings.request.input;

    const input: Input = .{
        .binding = @ptrCast(bindings),
        .imports = if (bindings.parsed.* == .indexed) zx.columns.slice(@FieldType(Input, "imports"), bindings.parsed.indexed.output.imports) else &.{},
        .count = bindings.edges.len,
        .row = 0,
        .symbols = &.{zx.columns.pointer(std.meta.Elem(@FieldType(Input, "symbols")), symbols)},
        .scope = @ptrCast(&scope),
        .scratch = @ptrCast(&scratch),
        .owner = @ptrCast(&allocator),
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

    rule.executeIn(scope.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.InvalidSourceGraph => return error.InvalidSourceGraph,
        else => unreachable,
    };

    return .{
        .functions = if (used[0] == 0) signature.function_imports else functions.rows(Binding)[0..@intCast(used[0])],
        .published = if (used[1] == 0) signature.reexport_functions else published.rows(Binding)[0..@intCast(used[1])],
    };
}

pub fn openMixedImport(handle: *const anyopaque, row: u64) State.Error!?*const Rows {
    const bindings = Bindings.borrow(handle);
    const index: usize = @intCast(row);

    return switch (bindings.parsed.*) {
        .native => |parsed| bindings.open(nativeHeader(parsed), index),
        .indexed => |*indexed| bindings.open(indexed.header(), index),
    };
}

pub fn rejectMixedImport(handle: *const anyopaque, row: u64, message: []const u8) State.Error!void {
    return Bindings.borrow(handle).reject(@intCast(row), message);
}

fn nativeHeader(parsed: @FieldType(Parse, "native")) zx.syntax.header.Native {
    return .{ .program = parsed.value.parsed.ast };
}

fn collectSeed(bindings: *Bindings, allocator: std.mem.Allocator, signature: *const Signature) State.Error!Result {
    const header = nativeHeader(bindings.parsed.native);
    var functions: std.ArrayList(Binding) = .empty;
    var published: std.ArrayList(Binding) = .empty;

    for (0..bindings.edges.len) |row| {
        const item = frontend.project.import_view.get(header, row);

        if (item.kind == .type_only) continue;

        const symbols = try bindings.dependency(row) orelse continue;
        var reporter: zx.Reporter = .{};

        const selected = Selection.selectSeed(bindings.state.scratch.allocator(), item, &symbols, &reporter) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return bindings.reject(row, reporter.diagnostic.?.message);
        };

        if (selected.functions.names.len == 0) continue;

        const target = if (item.exported) &published else &functions;
        const prefix = if (target.items.len != 0) &.{} else if (item.exported) signature.reexport_functions else signature.function_imports;

        try Selection.publishSeedFunctions(allocator, selected, bindings.members, target, prefix, true);
    }

    return .{
        .functions = if (functions.items.len == 0) signature.function_imports else functions.items,
        .published = if (published.items.len == 0) signature.reexport_functions else published.items,
    };
}
