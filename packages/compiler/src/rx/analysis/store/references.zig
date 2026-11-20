const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Store = @import("../store.zig");
const target = @import("../call/target.zig");
const Graph = @import("../project/source_graph/model.zig");
const Declarations = @import("../project/declarations.zig");
const generated = @import("rx_options").generated_graph;
const register = if (generated) @import("generated_rx_store_namespace").executeState else void;
const Parameters = if (generated) @typeInfo(@TypeOf(register)).@"fn" else void;
const Parameter = if (generated) Parameters.param_types[1].? else void;
const Registration = if (generated and @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Namespaces = if (generated) @FieldType(Registration, "index") else std.StringHashMapUnmanaged(void);
const Status = if (generated) @FieldType(@typeInfo(Parameters.return_type.?).error_union.payload, "status") else enum { Accepted, Invalid, Duplicate };
const Namespace = struct { name: []const u8, status: Status };
const empty: Namespaces = if (generated) frontend.project.source_index.emptyGenerated(Namespaces) else .empty;

const Row = struct {
    name: []const u8,
    path: []const u8,
    type_id: u32,
};

pub const Storage = std.MultiArrayList(Row);

/// The bindings and name descriptors are local to preparation. The strings themselves
/// are owned by the result so published getters and setters can keep using them.
pub const Scope = struct {
    names: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},
    types: []const u32 = &.{},
    pub fn at(self: Scope, index: usize) Store.Binding {
        return .{
            .name = self.names[index],
            .path = self.paths[index],
            .type_id = @fromBackingInt(self.types[index]),
        };
    }
};

pub const Value = union(enum) { scope: Scope, diagnostic: target.Diagnostic };

pub fn resolve(allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: rx.ModuleSource, edges: []const Graph.Edge, sources: Graph.Sources, definitions: []const Store.Definition) std.mem.Allocator.Error!Value {
    if (definitions.len == 0 or edges.len == 0) return .{ .scope = .{} };

    var bindings: Storage = .empty;
    var namespaces = empty;
    var references: Graph.References = .{ .edges = edges };
    var declarations = Declarations.init(source.node, .Store);

    defer if (!generated) namespaces.deinit(temporary);

    while (declarations.next()) |node| {
        const attributes = Declarations.attributes(node, .Store);
        const from = attributes.first;
        const edge = references.next(.store).edge;
        const definition = &definitions[sources.at(edge.target.source).store];
        const explicit = if (attributes.second) |named| named.value else null;
        const location = (attributes.second orelse from).value_location;
        const namespace = try claim(temporary, &namespaces, explicit, definition.name);

        switch (namespace.status) {
            .Accepted => {},
            .Invalid => return failure(allocator, source.path, location, "Store namespace must be an identifier; use as for a different display name"),
            .Duplicate => return failure(allocator, source.path, location, "Store namespace is already registered in this module"),
        }

        const published = if (comptime generated)
            try @import("references/publish.zig").append(allocator, temporary, namespace.name, definition.objects, &bindings)
        else
            try publishSeed(allocator, temporary, namespace.name, definition.objects, &bindings);

        if (!published) return failure(allocator, source.path, from.value_location, "Store Object names must be identifiers");
    }

    const rows = bindings.slice();

    return .{ .scope = .{ .names = rows.items(.name), .paths = rows.items(.path), .types = rows.items(.type_id) } };
}

fn claim(allocator: std.mem.Allocator, state: *Namespaces, explicit: ?[]const u8, fallback: []const u8) std.mem.Allocator.Error!Namespace {
    if (comptime !generated) {
        const name = explicit orelse fallback;

        if (!seedIdentifier(name)) return .{ .name = name, .status = .Invalid };

        const duplicate = (try state.getOrPut(allocator, name)).found_existing;

        return .{ .name = name, .status = if (duplicate) .Duplicate else .Accepted };
    }

    const input: Registration = .{ .index = state.*, .explicit = explicit, .fallback = fallback };

    const result = register(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.InvalidUtf8 => return .{ .name = explicit orelse fallback, .status = .Invalid },
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    state.* = result.index;

    return .{ .name = result.name, .status = result.status };
}

fn publishSeed(allocator: std.mem.Allocator, storage: std.mem.Allocator, scope: []const u8, objects: []const Store.Object, bindings: *Storage) std.mem.Allocator.Error!bool {
    for (objects) |*object| {
        if (!seedIdentifier(object.name)) return false;

        try bindings.append(storage, .{
            .name = try @import("names.zig").qualify(allocator, scope, object.name, .reference),
            .path = object.identity,
            .type_id = @backingInt(object.initial.output_type),
        });
    }

    return true;
}

fn seedIdentifier(name: []const u8) bool {
    return frontend.binding_path.valid(name) and std.mem.indexOfAny(u8, name, ".$") == null;
}

fn failure(allocator: std.mem.Allocator, path: []const u8, location: rx.ast.Location, message: []const u8) std.mem.Allocator.Error!Value {
    const failed = try target.failure(allocator, .{ .path = path, .location = location, .code = "capability", .message = message });

    return .{ .diagnostic = failed.diagnostic };
}
