const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Graph = @import("source_graph/model.zig");
const enabled = @import("rx_options").generated_graph;
const entry = if (enabled) @import("generated_rx_visit_declarations") else void;
const Input = if (enabled) std.meta.Child(entry.Input) else void;
pub const Kind = if (enabled) @FieldType(Input, "kind") else enum { Arguments, TypeImport, Store, Field };
pub const Error = std.mem.Allocator.Error || error{InvalidFlow};

pub const Attributes = struct {
    first: *const rx.ast.Attribute,
    second: ?*const rx.ast.Attribute,
};

pub fn walk(source: rx.ast.Node, comptime kind: Kind, work: anytype) Error!void {
    if (source.children.len == 0) return;
    if (comptime enabled) return visit(source, kind, work);

    for (source.children) |*node| {
        if (!seedMatches(node.*, kind)) continue;

        const attributes = seedAttributes(node, kind);

        if (kind == .Arguments) {
            try work.append(node, attributes);
        } else {
            try work.append(attributes);
        }
    }
}

fn visit(source: rx.ast.Node, comptime kind: Kind, work: anytype) Error!void {
    const Tree = std.meta.Child(@FieldType(Input, "tree"));
    const Layout = std.meta.Child(@FieldType(Tree, "layout"));
    const References = std.meta.Child(std.meta.Child(@FieldType(Input, "references")));
    const Targets = std.meta.Child(@FieldType(Input, "targets"));
    const TargetKind = std.meta.Child(@FieldType(Targets, "kinds"));
    const names = zx.memory.borrowTextColumn("name", source.children);
    const edges: []const Graph.Edge = if (kind == .Arguments) &.{} else work.references.edges;
    const store_names = if (kind == .Store) zx.memory.borrowTextColumn("name", work.definitions) else {};
    var buffer: [2048]u8 = undefined;
    const backing = if (kind == .Arguments) work.source.allocator else work.allocator;
    var local = std.heap.BufferFirstAllocator.init(&buffer, backing);
    var scratch = std.heap.ArenaAllocator.init(local.allocator());

    defer scratch.deinit();

    const allocator = scratch.allocator();
    const owners = try allocator.alloc(u64, edges.len);
    const kinds = try allocator.alloc(TargetKind, edges.len);

    for (edges, owners, kinds) |edge, *owner, *target_kind| {
        owner.* = if (edge.target == .source) edge.target.source else 0;

        target_kind.* = switch (edge.target) {
            .source => .Source,
            .compiled => .Compiled,
            .native => .Native,
        };
    }

    const plan = entry.executeIn(allocator, &.{
        .kind = kind,
        .names = @ptrCast(&names),
        .tree = &.{ .nodes = std.mem.sliceAsBytes(source.children), .borrowed = null, .layout = &comptime rx.astLayout(Layout) },
        .next = 0,
        .count = source.children.len,
        .edge = 0,
        .references = if (kind == .Arguments) null else &work.references.view(References, if (kind == .Store) .store else .type_import),
        .targets = &.{ .owners = owners, .kinds = kinds },
        .stores = if (kind == .Store) &.{ .names = @ptrCast(&store_names), .first = work.sources.rx_end } else null,
        .signatures = if (kind == .TypeImport) &.{
            .indices = @ptrCast(work.signatures.indices),
            .sources = &.{ .zx_count = work.signatures.graph.sources.zx_count, .rx_end = work.signatures.graph.sources.rx_end },
        } else null,
    }) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    for (plan.entries) |row| {
        switch (kind) {
            .Arguments => try work.append(@ptrCast(@alignCast(row.node.ptr)), .{
                .first = attribute(row.first),
                .second = attribute(row.second.?),
            }),
            .TypeImport => try work.publish(@intCast(row.index.?), attribute(row.second.?)),
            .Store => try work.publishDeclaration(@intCast(row.index.?), attribute(row.first), row.scope.?),
            .Field => unreachable,
        }
    }

    if (plan.failure) |failure| {
        const at = attribute(failure.at);

        switch (kind) {
            .TypeImport => return work.fail(at, failure.message),
            .Store => return work.fail(at.value_location, failure.message),
            .Arguments, .Field => unreachable,
        }
    }
}

pub inline fn attribute(bytes: []const u8) *const rx.ast.Attribute {
    std.debug.assert(bytes.len == @sizeOf(rx.ast.Attribute));

    return @ptrCast(@alignCast(bytes.ptr));
}

fn seedMatches(node: rx.ast.Node, kind: Kind) bool {
    return std.mem.eql(u8, node.name, switch (kind) {
        .Arguments => "Args",
        .TypeImport => "Type",
        .Store => "Store",
        .Field => "Field",
    });
}

pub fn seedAttributes(node: *const rx.ast.Node, kind: Kind) Attributes {
    const target = @import("../call/target.zig");

    const names: [2][]const u8 = switch (kind) {
        .Arguments => .{ "in", "out" },
        .Field => .{ "name", "value" },
        else => .{ "from", "as" },
    };

    var second = target.borrowAttribute(node.*, names[1]);

    if (kind == .Store) {
        for (node.attributes) |*item| if (std.mem.eql(u8, item.name, names[1])) {
            second = item;
        };
    }

    return .{ .first = target.borrowAttribute(node.*, names[0]).?, .second = second };
}
