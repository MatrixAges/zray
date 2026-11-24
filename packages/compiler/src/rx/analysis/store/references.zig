const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Store = @import("../store.zig");
const target = @import("../call/target.zig");
const Graph = @import("../project/source_graph/model.zig");
const Declarations = @import("../project/declarations.zig");
const generated = @import("rx_options").generated_graph;

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

pub fn resolve(allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: rx.ModuleSource, edges: []const Graph.Edge, sources: Graph.Sources, definitions: []const Store.Definition, issue: *?target.Diagnostic) Declarations.Error!Scope {
    if (definitions.len == 0 or edges.len == 0) return .{};

    var bindings: Storage = .empty;

    var work: Work = .{
        .allocator = allocator,
        .temporary = temporary,
        .owner = source.path,
        .references = .{ .edges = edges },
        .sources = sources,
        .definitions = definitions,
        .issue = issue,
        .bindings = &bindings,
    };

    defer if (!generated) work.namespaces.deinit(temporary);

    try Declarations.walk(source.node, .Store, &work);

    const rows = bindings.slice();

    return .{ .names = rows.items(.name), .paths = rows.items(.path), .types = rows.items(.type_id) };
}

const Work = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    owner: []const u8,
    references: Graph.References,
    sources: Graph.Sources,
    definitions: []const Store.Definition,
    issue: *?target.Diagnostic,
    bindings: *Storage,
    namespaces: if (generated) void else std.StringHashMapUnmanaged(void) = if (generated) {} else .empty,
    pub fn append(self: *Work, attributes: Declarations.Attributes) Declarations.Error!void {
        const row = self.references.next(.store).row;
        const item = self.definition(row);
        const at = attributes.second orelse attributes.first;
        const name = if (attributes.second) |alias| alias.value else item.name;

        if (!seedIdentifier(name)) return self.fail(at.value_location, "Store namespace must be an identifier; use as for a different display name");
        if ((try self.namespaces.getOrPut(self.temporary, name)).found_existing) return self.fail(at.value_location, "Store namespace is already registered in this module");
        try self.publish(item, attributes.first, name);
    }
    fn definition(self: *const Work, row: usize) *const Store.Definition {
        const source = self.references.edges[row].target.source;

        return &self.definitions[self.sources.at(source).store];
    }
    fn publish(self: *Work, item: *const Store.Definition, from: *const rx.ast.Attribute, namespace: []const u8) Declarations.Error!void {
        const published = if (comptime generated)
            try @import("references/publish.zig").append(self.allocator, self.temporary, namespace, item.objects, self.bindings)
        else
            try publishSeed(self.allocator, self.temporary, namespace, item.objects, self.bindings);

        if (!published) return self.fail(from.value_location, "Store Object names must be identifiers");
    }
    fn fail(self: *Work, location: rx.ast.Location, message: []const u8) Declarations.Error {
        const failed = try target.failure(self.allocator, .{ .path = self.owner, .location = location, .code = "capability", .message = message });

        self.issue.* = failed.diagnostic;

        return error.InvalidFlow;
    }
};

fn borrow(handle: *const anyopaque) *Work {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn storeDeclarationName(handle: *const anyopaque, row: ?u64) []const u8 {
    return borrow(handle).definition(@intCast(row.?)).name;
}

pub fn publishStoreDeclaration(handle: *const anyopaque, row: ?u64, from: []const u8, namespace: []const u8) Declarations.Error!void {
    const work = borrow(handle);

    try work.publish(work.definition(@intCast(row.?)), Declarations.attribute(from), namespace);
}

pub fn rejectStoreDeclaration(handle: *const anyopaque, at: []const u8, message: []const u8) Declarations.Error!void {
    return borrow(handle).fail(Declarations.attribute(at).value_location, message);
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
