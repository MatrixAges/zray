const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Store = @import("../store.zig");
const target = @import("../call/target.zig");
const Graph = @import("../project/source_graph/model.zig");
const Signatures = @import("../project/references/signatures.zig");
const Contract = @import("../module.zig").Contract;
const Index = frontend.project.source_index.Map;
pub const Data = struct { definitions: []Store.Definition, context: frontend.Context };
pub const Value = union(enum) { data: Data, diagnostic: target.Diagnostic };

pub fn load(allocator: std.mem.Allocator, sources: []const rx.ModuleSource, context: frontend.Context) std.mem.Allocator.Error!Value {
    return loadIn(allocator, allocator, sources, context, &.{}, null);
}

pub fn loadSignatures(allocator: std.mem.Allocator, sources: []const rx.ModuleSource, context: frontend.Context, edges: []const []const Graph.Edge, signatures: Signatures) std.mem.Allocator.Error!Value {
    return loadSignaturesIn(allocator, allocator, sources, context, edges, signatures);
}

pub fn loadSignaturesIn(allocator: std.mem.Allocator, backing: std.mem.Allocator, sources: []const rx.ModuleSource, context: frontend.Context, edges: []const []const Graph.Edge, signatures: Signatures) std.mem.Allocator.Error!Value {
    return loadIn(allocator, backing, sources, context, edges, signatures);
}

pub fn publish(allocator: std.mem.Allocator, definitions: []Store.Definition, contract: *const Contract, comptime ownership: enum { Owned, Retained }) std.mem.Allocator.Error![]Store.Definition {
    const retained = ownership == .Retained;
    const result = if (retained) try allocator.dupe(Store.Definition, definitions) else definitions;

    for (result) |*definition| {
        const objects = if (retained) try allocator.dupe(Store.Object, definition.objects) else @constCast(definition.objects);

        for (objects) |*object| {
            object.initial.types = contract.types;
            object.initial.native_modules = contract.native_modules;
        }

        definition.types = contract.types;
        definition.objects = objects;
    }

    return result;
}

fn loadIn(allocator: std.mem.Allocator, backing: std.mem.Allocator, sources: []const rx.ModuleSource, context: frontend.Context, edges: []const []const Graph.Edge, signatures: ?Signatures) std.mem.Allocator.Error!Value {
    const definitions = try allocator.alloc(Store.Definition, sources.len);
    var paths: Index = if (signatures == null) try Index.init(backing, sources.len) else .empty;
    var value_memory = std.heap.ArenaAllocator.init(backing);
    var shared = context;

    defer paths.deinit(backing);
    defer value_memory.deinit();

    for (sources, definitions, 0..) |source, *definition, index| {
        defer _ = value_memory.reset(.retain_capacity);
        const imports = @import("../project/type_imports.zig");
        var issue: ?target.Diagnostic = null;

        const aliases = if (signatures) |signed|
            imports.collect(allocator, value_memory.allocator(), source, edges[index], signed, shared.types.kinds, &issue) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFlow => return .{ .diagnostic = issue.? },
            }

        else
            imports.Imports{};

        const result = try Store.analyzeWithValues(allocator, backing, .{
            .owner = source.path,
            .node = source.node,
            .types = shared.types,
            .nominal_types = shared.nominal_types,
            .native_modules = shared.native_modules,
            .aliases = aliases.types,
        }, aliases.values);

        if (result == .diagnostic) return .{ .diagnostic = result.diagnostic };

        definition.* = result.definition;

        if (signatures == null and !paths.claim(index, definition.source_path)) {
            const failed = try target.failure(allocator, .{ .path = source.path, .location = source.node.location, .code = "module", .message = "Store definition path is already registered" });

            return .{ .diagnostic = failed.diagnostic };
        }

        shared.types = definition.types;
    }

    return .{ .data = .{ .definitions = definitions, .context = shared } };
}
