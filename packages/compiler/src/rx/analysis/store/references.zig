const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const ir = zx.ir;
const Store = @import("../store.zig");
const target = @import("../call/target.zig");
const Graph = @import("../project/source_graph/model.zig");
const generated = @import("rx_options").generated_graph;
const register = if (generated) @import("generated_rx_store_namespace").executeState else void;
const Parameters = if (generated) @typeInfo(@TypeOf(register)).@"fn" else void;
const Parameter = if (generated) Parameters.param_types[1].? else void;
const Registration = if (generated and @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Namespaces = if (generated) @FieldType(Registration, "index") else std.StringHashMapUnmanaged(void);
const Status = if (generated) @FieldType(@typeInfo(Parameters.return_type.?).error_union.payload, "status") else enum { Accepted, Invalid, Duplicate };

const empty: Namespaces = if (generated) .{
    .keys = .{ .items = &.{}, .storage = .plain },
    .values = .{ .items = &.{}, .storage = .plain },
    .buckets = .{ .items = &.{}, .storage = .plain },
} else .empty;

const Row = struct {
    name: []const u8,
    path: []const u8,
    type_id: ir.TypeId,
};

/// The bindings and name descriptors are local to preparation. The strings themselves
/// are owned by the result so published getters and setters can keep using them.
pub const Scope = struct {
    names: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},
    types: []const ir.TypeId = &.{},
    pub fn at(self: Scope, index: usize) Store.Binding {
        return .{
            .name = self.names[index],
            .slot = .{
                .path = self.paths[index],
                .type_id = self.types[index],
                .writable = false,
            },
        };
    }
};

pub const Value = union(enum) { scope: Scope, diagnostic: target.Diagnostic };

pub fn resolve(allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: rx.ModuleSource, edges: []const Graph.Edge, sources: Graph.Sources, definitions: []const Store.Definition) std.mem.Allocator.Error!Value {
    if (definitions.len == 0 or edges.len == 0) return .{ .scope = .{} };

    var bindings: std.MultiArrayList(Row) = .empty;
    var namespaces = empty;
    var references: Graph.References = .{ .remaining = edges };

    defer if (!generated) namespaces.deinit(temporary);

    for (source.node.children) |node| {
        if (!std.mem.eql(u8, node.name, "Store")) continue;

        const from = target.attribute(node, "from");
        const edge = references.next(.store);
        const definition = &definitions[sources.at(edge.target.source).store];
        var alias = definition.name;
        var location = from.value_location;

        for (node.attributes) |attribute| if (std.mem.eql(u8, attribute.name, "as")) {
            alias = attribute.value;
            location = attribute.value_location;
        };

        switch (try claim(temporary, &namespaces, alias)) {
            .Accepted => {},
            .Invalid => return failure(allocator, source.path, location, "Store namespace must be an identifier; use as for a different display name"),
            .Duplicate => return failure(allocator, source.path, location, "Store namespace is already registered in this module"),
        }

        for (definition.objects) |object| {
            const name = (try objectName(allocator, alias, object.name)) orelse return failure(allocator, source.path, from.value_location, "Store Object names must be identifiers");

            try bindings.append(temporary, .{
                .name = name,
                .path = object.identity,
                .type_id = object.initial.output_type,
            });
        }
    }

    const rows = bindings.slice();

    return .{ .scope = .{ .names = rows.items(.name), .paths = rows.items(.path), .types = rows.items(.type_id) } };
}

fn claim(allocator: std.mem.Allocator, state: *Namespaces, name: []const u8) std.mem.Allocator.Error!Status {
    if (comptime !generated) {
        if (!seedIdentifier(name)) return .Invalid;

        return if ((try state.getOrPut(allocator, name)).found_existing) .Duplicate else .Accepted;
    }

    const input: Registration = .{ .index = state.*, .name = name };

    const result = register(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.InvalidUtf8 => return .Invalid,
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    state.* = result.index;

    return result.status;
}

fn objectName(allocator: std.mem.Allocator, scope: []const u8, name: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (comptime !generated) {
        if (!seedIdentifier(name)) return null;

        return try @import("names.zig").qualify(allocator, scope, name, .reference);
    }

    const rule = @import("generated_rx_store_reference_name");
    const input: std.meta.Child(rule.Input) = .{ .scope = scope, .object = name };

    return zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.InvalidUtf8 => null,
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn seedIdentifier(name: []const u8) bool {
    return frontend.binding_path.valid(name) and std.mem.indexOfAny(u8, name, ".$") == null;
}

fn failure(allocator: std.mem.Allocator, path: []const u8, location: rx.ast.Location, message: []const u8) std.mem.Allocator.Error!Value {
    const failed = try target.failure(allocator, .{ .path = path, .location = location, .code = "capability", .message = message });

    return .{ .diagnostic = failed.diagnostic };
}
