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
    var publication: Publication = .{ .allocator = allocator, .definitions = result, .contract = contract };

    if (comptime generated) {
        const rule = @import("generated_rx_publish_store_registry");
        var scratch = std.heap.ArenaAllocator.init(allocator);

        defer scratch.deinit();

        rule.executeIn(scratch.allocator(), &.{
            .retained = retained,
            .count = result.len,
            .row = 0,
        }, &publication) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    } else for (0..result.len) |row| {
        try publication.apply(row, retained);
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
            var scratch = std.heap.ArenaAllocator.init(work.backing);

            defer scratch.deinit();

            return rule.executeIn(scratch.allocator(), &.{
                .count = work.sources.len,
                .row = 0,
            }, work) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSource => error.InvalidSource,
                else => unreachable,
            };
        }

        for (0..work.sources.len) |row| {
            try work.bindAliases(row);
            try work.compileEntry(row);
        }
    }
    pub fn commit(work: *Load, pending: anytype) Error!void {
        if (pending.store_0) |effect| switch (effect.step) {
            .BindAliases => try work.bindAliases(@intCast(effect.row)),
            .Compile => try work.compileEntry(@intCast(effect.row)),
        };
    }

    fn bindAliases(work: *Load, index: usize) Error!void {
        work.aliases = Imports.collect(work.allocator, work.values.allocator(), work.sources[index], work.edges[index], work.signatures, work.data.context.types.kinds, &work.issue) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFlow => return error.InvalidSource,
        };
    }
    fn compileEntry(work: *Load, index: usize) Error!void {
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
        work.data.context.types = result.definition.types;
        _ = work.values.reset(.retain_capacity);
    }
};

const Publication = struct {
    allocator: std.mem.Allocator,
    definitions: []Store.Definition,
    contract: *const Contract,
    pub fn commit(self: *Publication, pending: anytype) std.mem.Allocator.Error!void {
        if (pending.store_0) |definition| {
            try self.apply(@intCast(definition.row), definition.copy_objects);
        }
    }
    fn apply(self: *Publication, row: usize, copy_objects: bool) std.mem.Allocator.Error!void {
        const definition = &self.definitions[row];
        const objects = if (copy_objects) try self.allocator.dupe(Store.Object, definition.objects) else definition.objects;

        definition.types = self.contract.types;
        definition.objects = objects;

        for (objects) |*object| {
            object.initial.types = self.contract.types;
            object.initial.native_modules = self.contract.native_modules;
        }
    }
};
