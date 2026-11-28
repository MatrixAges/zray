const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const State = @import("state.zig");
const Edge = @import("../source_graph/model.zig").Edge;
const Binding = std.meta.Child(@FieldType(frontend.ResolvedImports, "imports"));
const Signature = frontend.project.signature_project.Module;
const Selection = frontend.project.import_binding;
const enabled = @import("rx_options").generated_graph and frontend.project.ParseCache.indexed_enabled;
const Parse = frontend.project.ParseCache.ModuleResult;
const rule = if (enabled) @import("generated_rx_mixed_import_bindings") else void;
const Input = if (enabled) std.meta.Child(rule.Input) else void;
const StoreState = if (enabled) std.meta.Child(@FieldType(rule.zx_pending, "store_0")) else void;
const Rows = if (enabled) std.meta.Child(std.meta.Child(@FieldType(std.meta.Child(StoreState), "rows"))) else void;
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
    publication: Publication = undefined,
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

        const target, const prefix = self.publication.target(item.exported);

        self.rows = .{
            .stride = @sizeOf(Binding),
            .prefix = if (target.items.len == 0) prefix.len else 0,
            .named = std.mem.sliceAsBytes(self.members.named),
            .fallback = if (self.members.default) |member| std.mem.asBytes(member) else &.{},
            .exported = item.exported,
        };

        return &self.rows;
    }
};

const StoreHost = if (enabled) struct {
    bindings: *Bindings,
    store_0: *StoreState,
    snapshot: *std.meta.Child(StoreState),
    pub fn commit(self: *StoreHost, pending: anytype) State.Error!void {
        const effect = pending.store_0 orelse return;
        const bindings = self.bindings;

        if (effect.message) |message| return bindings.reject(@intCast(effect.row), message);
        if (effect.publication) |plan| return bindings.publication.commit(plan);

        const index: usize = @intCast(effect.row);

        const rows = switch (bindings.parsed.*) {
            .native => |parsed| try bindings.open(nativeHeader(parsed), index),
            .indexed => |*indexed| try bindings.open(indexed.header(), index),
        };

        self.snapshot.* = effect.*;
        self.snapshot.rows = rows;
        self.store_0.* = self.snapshot;
    }
} else void;

const Publication = struct {
    allocator: std.mem.Allocator,
    signature: *const Signature,
    functions: std.ArrayList(Binding) = .empty,
    published: std.ArrayList(Binding) = .empty,
    fn target(self: *Publication, exported: bool) struct { *std.ArrayList(Binding), []const Binding } {
        return if (exported)
            .{ &self.published, self.signature.reexport_functions }

        else
            .{ &self.functions, self.signature.function_imports };
    }
    fn commit(self: *Publication, plan: anytype) std.mem.Allocator.Error!void {
        if (!plan.fits) return error.OutOfMemory;

        const output, const prefix = self.target(plan.exported);
        const count: usize = @intCast(plan.prefix);

        try output.ensureUnusedCapacity(self.allocator, count + plan.names.len);

        output.appendSliceAssumeCapacity(prefix[0..count]);

        for (plan.names, plan.sources) |name, source| {
            std.debug.assert(source.len == @sizeOf(Binding));

            var row = std.mem.bytesToValue(Binding, source);

            row.name = try self.allocator.dupe(u8, name);

            output.appendAssumeCapacity(row);
        }
    }
    fn deinit(self: *Publication) void {
        self.release(&self.functions, self.signature.function_imports.len);
        self.release(&self.published, self.signature.reexport_functions.len);
    }
    fn release(self: *Publication, rows: *std.ArrayList(Binding), prefix: usize) void {
        if (rows.items.len != 0) {
            for (rows.items[prefix..]) |row| self.allocator.free(row.name);
        }

        rows.deinit(self.allocator);
    }
};

fn collectSource(bindings: *Bindings, allocator: std.mem.Allocator, signature: *const Signature) State.Error!Result {
    var scratch = std.heap.ArenaAllocator.init(bindings.state.scratch.child_allocator);

    defer scratch.deinit();

    bindings.publication = .{ .allocator = allocator, .signature = signature };

    errdefer bindings.publication.deinit();

    const symbols: *const @TypeOf(bindings.request.input) = &bindings.request.input;

    const input: Input = .{
        .count = bindings.edges.len,
        .row = 0,
        .symbols = &.{zx.columns.pointer(std.meta.Elem(@FieldType(Input, "symbols")), symbols)},
    };

    var snapshot: std.meta.Child(StoreState) = .{ .row = 0, .publication = null, .message = null, .rows = null };
    var store: StoreState = &snapshot;
    var host: StoreHost = .{ .bindings = bindings, .store_0 = &store, .snapshot = &snapshot };

    rule.executeIn(scratch.allocator(), &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.InvalidSourceGraph => return error.InvalidSourceGraph,
        else => unreachable,
    };

    const publication = &bindings.publication;

    return .{
        .functions = if (publication.functions.items.len == 0) signature.function_imports else publication.functions.items,
        .published = if (publication.published.items.len == 0) signature.reexport_functions else publication.published.items,
    };
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
