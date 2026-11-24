const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
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
    const names = zx.memory.borrowTextColumn("name", source.children);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const allocator = if (kind == .Store) work.temporary else scratch.allocator();

    entry.executeIn(allocator, &.{
        .target = @ptrCast(work),
        .kind = kind,
        .names = @ptrCast(&names),
        .tree = &.{ .nodes = std.mem.sliceAsBytes(source.children), .borrowed = null, .layout = &comptime rx.astLayout(Layout) },
        .next = 0,
        .count = source.children.len,
        .edge = 0,
        .references = if (kind == .Arguments) null else &work.references.view(References, if (kind == .Store) .store else .type_import),
        .signatures = if (kind == .TypeImport) &.{
            .indices = @ptrCast(work.signatures.indices),
            .sources = &.{ .zx_count = work.signatures.graph.sources.zx_count, .rx_end = work.signatures.graph.sources.rx_end },
        } else null,
    }) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        error.OutOfMemory, error.InvalidFlow => return @errorCast(err),
        else => unreachable,
    };
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
