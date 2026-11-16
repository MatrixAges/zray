const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const expressions = @import("frontend").expressions;
const target = @import("../call/target.zig");
const Graph = @import("source_graph/model.zig");
const Signatures = @import("references/signatures.zig");
const Declarations = @import("declarations.zig");
const generated = @import("rx_options").generated_graph;

pub const Imports = struct {
    types: []const zx.ir.Export = &.{},
    values: expressions.BindingColumns = .{},
};

pub const Value = union(enum) { imports: Imports, diagnostic: target.Diagnostic };

pub fn values(allocator: std.mem.Allocator, types: zx.ir.TypeTable, imports: []const zx.ir.Export) std.mem.Allocator.Error!expressions.BindingColumns {
    var result: expressions.BindingStorage = .empty;

    if (comptime generated) {
        try @import("type_imports/publish.zig").append(allocator, allocator, imports, types.kinds, &result, null);
    } else {
        for (imports) |alias| {
            if (valueKind(types.kinds[@backingInt(alias.type_id)])) {
                try result.append(allocator, .{ .name = alias.name, .type_id = alias.type_id });
            }
        }
    }

    return expressions.BindingColumns.view(result.slice());
}

pub fn collect(allocator: std.mem.Allocator, value_allocator: std.mem.Allocator, source: rx.ModuleSource, edges: []const Graph.Edge, signatures: Signatures, kinds: []const u8) std.mem.Allocator.Error!Value {
    var references: Graph.References = .{ .edges = edges };
    var types: std.ArrayList(zx.ir.Export) = .empty;
    var visible: expressions.BindingStorage = .empty;
    var declarations = Declarations.init(source.node, .TypeImport);

    while (declarations.next()) |node| {
        const attributes = Declarations.attributes(node, .TypeImport);
        const from = attributes.first;
        const alias = attributes.second orelse return failure(allocator, source, from, "Type requires an explicit as attribute");
        const reference = references.next(.type_import).edge;
        const signature = admit(&signatures, reference);

        const index = switch (signature.status) {
            .Resolved => signature.index.?,
            .NonSource => return failure(allocator, source, from, "Type requires a ZX source module"),
            .Native => return failure(allocator, source, from, "native and standard imports must use the interface registry"),
            .MissingSignature => return failure(allocator, source, from, "Type source signature is missing from the analyzed input set"),
        };

        const exports = signatures.modules[@intCast(index)].signature.exports;

        try types.ensureUnusedCapacity(allocator, exports.len);

        if (comptime generated) {
            try @import("type_imports/publish.zig").append(allocator, value_allocator, exports, kinds, &visible, .{
                .alias = alias.value,
                .rows = types.unusedCapacitySlice()[0..exports.len],
            });

            types.items.len += exports.len;
        } else {
            for (exports) |exported| {
                const row = @backingInt(exported.type_id);
                const name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ alias.value, exported.name });

                types.appendAssumeCapacity(.{ .name = name, .type_id = exported.type_id });

                if (row < kinds.len and valueKind(kinds[row])) {
                    try visible.append(value_allocator, .{ .name = name, .type_id = exported.type_id });
                }
            }
        }
    }

    return .{ .imports = .{ .types = types.items, .values = expressions.BindingColumns.view(visible.slice()) } };
}

const admission = if (generated) @import("generated_rx_type_import_admit") else void;

const Decision = if (generated) @typeInfo(@TypeOf(admission.executeValue(undefined, undefined))).error_union.payload else struct {
    status: enum { Resolved, NonSource, Native, MissingSignature },
    index: ?i64 = null,
};

fn admit(signatures: *const Signatures, edge: *const Graph.Edge) Decision {
    if (comptime generated) {
        const ranges = signatures.graph.sources;
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        return admission.executeValue(scratch.allocator(), &.{
            .target = switch (edge.target) {
                .source => .Source,
                .compiled => .Compiled,
                .native => .Native,
            },
            .signature = &.{
                .owner = if (edge.target == .source) edge.target.source else 0,
                .sources = &.{ .zx_count = ranges.zx_count, .rx_end = ranges.rx_end },
                .indices = signatures.indices,
            },
        }) catch unreachable;
    }

    const index = switch (edge.target) {
        .source => |row| row,
        .compiled => return .{ .status = .NonSource },
        .native => return .{ .status = .Native },
    };

    if (signatures.graph.sources.at(index) != .zx) return .{ .status = .NonSource };

    const row = Signatures.indexAt(signatures.indices, index) orelse return .{ .status = .MissingSignature };

    return .{ .status = .Resolved, .index = @intCast(row) };
}

fn valueKind(kind: u8) bool {
    return kind == @backingInt(std.meta.Tag(zx.ir.Type).enumeration);
}

fn failure(allocator: std.mem.Allocator, source: rx.ModuleSource, attribute: *const rx.ast.Attribute, message: []const u8) std.mem.Allocator.Error!Value {
    return .{ .diagnostic = .{
        .path = try allocator.dupe(u8, source.path),
        .location = attribute.value_location,
        .code = "module",
        .message = message,
    } };
}
