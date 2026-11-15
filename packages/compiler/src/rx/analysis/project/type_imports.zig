const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const expressions = @import("frontend").expressions;
const target = @import("../call/target.zig");
const Graph = @import("source_graph/model.zig");
const Signatures = @import("references/signatures.zig");
const generated = @import("rx_options").generated_graph;

pub const Imports = struct {
    types: []const zx.ir.Export = &.{},
    values: expressions.BindingColumns = .{},
};

pub const Value = union(enum) { imports: Imports, diagnostic: target.Diagnostic };

pub fn values(allocator: std.mem.Allocator, types: zx.ir.TypeTable, imports: []const zx.ir.Export) std.mem.Allocator.Error!expressions.BindingColumns {
    var result: expressions.BindingStorage = .empty;

    for (imports) |alias| {
        if (valueKind(types.kinds[@backingInt(alias.type_id)])) {
            try result.append(allocator, .{ .name = alias.name, .type_id = alias.type_id });
        }
    }

    return expressions.BindingColumns.view(result.slice());
}

pub fn collect(allocator: std.mem.Allocator, value_allocator: std.mem.Allocator, source: rx.ModuleSource, edges: []const Graph.Edge, signatures: Signatures, kinds: []const u8) std.mem.Allocator.Error!Value {
    var references: Graph.References = .{ .remaining = edges };
    var types: std.ArrayList(zx.ir.Export) = .empty;
    var visible: expressions.BindingStorage = .empty;

    for (source.node.children) |node| {
        if (!std.mem.eql(u8, node.name, "Type")) continue;

        const from = target.attribute(node, "from");
        const alias = target.optionalAttribute(node, "as") orelse return failure(allocator, source, from, "Type requires an explicit as attribute");
        const reference = references.next(.type_import);

        const index = switch (reference.target) {
            .source => |index| index,
            .compiled => return failure(allocator, source, from, "Type requires a ZX source module"),
            .native => return failure(allocator, source, from, "native and standard imports must use the interface registry"),
        };

        if (signatures.graph.sources.at(index) != .zx) return failure(allocator, source, from, "Type requires a ZX source module");

        const signature = signatures.get(index) orelse return failure(allocator, source, from, "Type source signature is missing from the analyzed input set");

        try types.ensureUnusedCapacity(allocator, signature.signature.exports.len);

        for (signature.signature.exports) |exported| {
            const row = @backingInt(exported.type_id);
            const kind = if (row < kinds.len) kinds[row] else null;
            const qualified = try qualify(allocator, alias.value, exported.name, kind);
            const item: zx.ir.Export = .{ .name = qualified.name, .type_id = exported.type_id };

            types.appendAssumeCapacity(item);

            if (qualified.value_visible) try visible.append(value_allocator, .{ .name = item.name, .type_id = item.type_id });
        }
    }

    return .{ .imports = .{ .types = types.items, .values = expressions.BindingColumns.view(visible.slice()) } };
}

const Qualified = struct { name: []const u8, value_visible: bool };

fn qualify(allocator: std.mem.Allocator, alias: []const u8, member: []const u8, kind: ?u8) std.mem.Allocator.Error!Qualified {
    if (comptime !generated) return .{ .name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ alias, member }), .value_visible = if (kind) |value| valueKind(value) else false };

    const rule = @import("generated_rx_qualify_type");
    const input: std.meta.Child(rule.Input) = .{ .alias = alias, .member = member, .kind = kind };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .name = result.name, .value_visible = result.value_visible };
}

fn valueKind(kind: u8) bool {
    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_rx_type_value_kind").executeValue(empty.allocator(), kind) catch unreachable;
    }

    return kind == @backingInt(std.meta.Tag(zx.ir.Type).enumeration);
}

fn failure(allocator: std.mem.Allocator, source: rx.ModuleSource, attribute: rx.ast.Attribute, message: []const u8) std.mem.Allocator.Error!Value {
    return .{ .diagnostic = .{
        .path = try allocator.dupe(u8, source.path),
        .location = attribute.value_location,
        .code = "module",
        .message = message,
    } };
}
