const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Store = @import("../store.zig");
const target = @import("../call/target.zig");
const Graph = @import("../project/source_graph/model.zig");
const Signatures = @import("../project/references/signatures.zig");
const Contract = @import("../module.zig").Contract;
const Imports = @import("../project/type_imports.zig");
const generated = @import("rx_options").generated_graph;
const Error = std.mem.Allocator.Error || error{InvalidSource};
pub const Data = struct { definitions: []Store.Definition, context: frontend.Context };
pub const Value = union(enum) { data: Data, diagnostic: target.Diagnostic };

pub fn loadSignatures(allocator: std.mem.Allocator, sources: []const rx.ModuleSource, context: frontend.Context, edges: []const []const Graph.Edge, signatures: Signatures) std.mem.Allocator.Error!Value {
    return loadSignaturesIn(allocator, allocator, sources, context, edges, signatures);
}

pub fn loadSignaturesIn(allocator: std.mem.Allocator, backing: std.mem.Allocator, sources: []const rx.ModuleSource, context: frontend.Context, edges: []const []const Graph.Edge, signatures: Signatures) std.mem.Allocator.Error!Value {
    if (sources.len == 0) return .{ .data = .{ .definitions = &.{}, .context = context } };

    var work: Load = .{
        .allocator = allocator,
        .backing = backing,
        .sources = sources,
        .edges = edges,
        .signatures = signatures,
        .data = .{ .definitions = try allocator.alloc(Store.Definition, sources.len), .context = context },
        .values = std.heap.ArenaAllocator.init(backing),
    };

    defer work.values.deinit();

    work.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSource => return .{ .diagnostic = work.issue.? },
    };

    return .{ .data = work.data };
}

pub fn publish(allocator: std.mem.Allocator, definitions: []Store.Definition, contract: *const Contract, retained: bool) std.mem.Allocator.Error![]Store.Definition {
    if (definitions.len == 0) return definitions;

    const result = if (retained) try allocator.dupe(Store.Definition, definitions) else definitions;
    var publication: Publication = .{ .allocator = allocator, .definitions = result, .contract = contract, .retained = retained };

    if (comptime generated) {
        const rule = @import("generated_rx_publish_store_registry");

        rule.executeIn(.failing, &.{
            .state = @ptrCast(&publication),
            .count = result.len,
            .row = 0,
            .tables = &.{
                .types = @ptrCast(&publication.types),
                .natives = @ptrCast(&publication.natives),
                .type_view = std.mem.asBytes(&contract.types),
                .native_view = std.mem.asBytes(&contract.native_modules),
            },
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    } else for (0..result.len) |row| {
        for (try publication.open(row)) |*object| {
            object.initial.types = contract.types;
            object.initial.native_modules = contract.native_modules;
        }
    }

    return result;
}

const Load = struct {
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    sources: []const rx.ModuleSource,
    edges: []const []const Graph.Edge,
    signatures: Signatures,
    data: Data,
    values: std.heap.ArenaAllocator,
    aliases: Imports.Imports = .{},
    issue: ?target.Diagnostic = null,
    fn run(work: *Load) Error!void {
        if (comptime generated) {
            const rule = @import("generated_rx_load_store_registry");
            const data: []Data = @as(*[1]Data, @ptrCast(&work.data));
            const shared = zx.memory.borrowNestedWriteColumn(zx.ir.TypeTable, &.{ "context", "types" }, data);

            return rule.executeIn(.failing, &.{
                .state = @ptrCast(work),
                .count = work.sources.len,
                .row = 0,
                .types = @ptrCast(&shared),
                .scratch = @ptrCast(&work.values),
            }) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSource => error.InvalidSource,
                else => unreachable,
            };
        }

        for (0..work.sources.len) |row| {
            try bindStoreRegistryAliases(work, row);

            _ = try compileStoreRegistryEntry(work, row);
            work.data.context.types = work.data.definitions[row].types;
            _ = work.values.reset(.retain_capacity);
        }
    }

    fn borrow(handle: *const anyopaque) *Load {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn bindStoreRegistryAliases(handle: *const anyopaque, row: u64) Error!void {
    const work = Load.borrow(handle);
    const index: usize = @intCast(row);

    work.aliases = Imports.collect(work.allocator, work.values.allocator(), work.sources[index], work.edges[index], work.signatures, work.data.context.types.kinds, &work.issue) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFlow => return error.InvalidSource,
    };
}

pub fn compileStoreRegistryEntry(handle: *const anyopaque, row: u64) Error![]const u8 {
    const work = Load.borrow(handle);
    const index: usize = @intCast(row);
    const source = &work.sources[index];
    const context = &work.data.context;

    const result = try Store.analyzeWithValues(work.allocator, work.backing, .{
        .owner = source.path,
        .node = source.node,
        .types = context.types,
        .nominal_types = context.nominal_types,
        .native_modules = context.native_modules,
        .aliases = work.aliases.types,
    }, work.aliases.values);

    if (result == .diagnostic) {
        work.issue = result.diagnostic;

        return error.InvalidSource;
    }

    work.data.definitions[index] = result.definition;

    return std.mem.asBytes(&work.data.definitions[index].types);
}

const Publication = struct {
    allocator: std.mem.Allocator,
    definitions: []Store.Definition,
    contract: *const Contract,
    retained: bool,
    types: zx.memory.WriteColumn = undefined,
    natives: zx.memory.WriteColumn = undefined,
    fn open(work: *Publication, row: usize) std.mem.Allocator.Error![]Store.Object {
        const definition = &work.definitions[row];
        const objects = if (work.retained) try work.allocator.dupe(Store.Object, definition.objects) else @constCast(definition.objects);

        definition.types = work.contract.types;
        definition.objects = objects;

        return objects;
    }
};

pub fn openStoreRegistryPublication(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!u64 {
    const work: *Publication = @ptrCast(@alignCast(@constCast(handle)));
    const objects = try work.open(@intCast(row));

    work.types = zx.memory.borrowNestedWriteColumn(zx.ir.TypeTable, &.{ "initial", "types" }, objects);
    work.natives = zx.memory.borrowNestedWriteColumn(zx.ir.NativeModuleTable, &.{ "initial", "native_modules" }, objects);

    return objects.len;
}
