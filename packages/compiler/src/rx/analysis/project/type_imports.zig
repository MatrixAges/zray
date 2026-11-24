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

pub fn collect(allocator: std.mem.Allocator, value_allocator: std.mem.Allocator, source: rx.ModuleSource, edges: []const Graph.Edge, signatures: Signatures, kinds: []const u8, issue: *?target.Diagnostic) Declarations.Error!Imports {
    var types: std.ArrayList(zx.ir.Export) = .empty;
    var visible: expressions.BindingStorage = .empty;

    var work: Work = .{
        .allocator = allocator,
        .value_allocator = value_allocator,
        .owner = source.path,
        .references = .{ .edges = edges },
        .signatures = signatures,
        .kinds = kinds,
        .issue = issue,
        .types = &types,
        .visible = &visible,
    };

    try Declarations.walk(source.node, .TypeImport, &work);

    return .{ .types = types.items, .values = expressions.BindingColumns.view(visible.slice()) };
}

const Work = struct {
    allocator: std.mem.Allocator,
    value_allocator: std.mem.Allocator,
    owner: []const u8,
    references: Graph.References,
    signatures: Signatures,
    kinds: []const u8,
    issue: *?target.Diagnostic,
    types: *std.ArrayList(zx.ir.Export),
    visible: *expressions.BindingStorage,
    pub fn append(self: *Work, attributes: Declarations.Attributes) Declarations.Error!void {
        const from = attributes.first;
        const alias = attributes.second orelse return self.fail(from, "Type requires an explicit as attribute");
        const edge = self.references.next(.type_import).edge;

        const owner = switch (edge.target) {
            .source => |row| row,
            .compiled => return self.fail(from, "Type requires a ZX source module"),
            .native => return self.fail(from, "native and standard imports must use the interface registry"),
        };

        if (self.signatures.graph.sources.at(owner) != .zx) return self.fail(from, "Type requires a ZX source module");

        const index = Signatures.indexAt(self.signatures.indices, owner) orelse return self.fail(from, "Type source signature is missing from the analyzed input set");

        try self.publish(index, alias);
    }
    fn publish(self: *Work, index: usize, alias: *const rx.ast.Attribute) std.mem.Allocator.Error!void {
        const exports = self.signatures.modules[index].signature.exports;

        try self.types.ensureUnusedCapacity(self.allocator, exports.len);

        if (comptime generated) {
            try @import("type_imports/publish.zig").append(self.allocator, self.value_allocator, exports, self.kinds, self.visible, .{
                .alias = alias.value,
                .rows = self.types.unusedCapacitySlice()[0..exports.len],
            });

            self.types.items.len += exports.len;
        } else {
            for (exports) |exported| {
                const row = @backingInt(exported.type_id);
                const name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ alias.value, exported.name });

                self.types.appendAssumeCapacity(.{ .name = name, .type_id = exported.type_id });

                if (row < self.kinds.len and valueKind(self.kinds[row])) {
                    try self.visible.append(self.value_allocator, .{ .name = name, .type_id = exported.type_id });
                }
            }
        }
    }

    fn fail(self: *Work, from: *const rx.ast.Attribute, message: []const u8) Declarations.Error {
        self.issue.* = .{
            .path = try self.allocator.dupe(u8, self.owner),
            .location = from.value_location,
            .code = "module",
            .message = message,
        };

        return error.InvalidFlow;
    }
};

fn borrow(handle: *const anyopaque) *Work {
    return @ptrCast(@alignCast(@constCast(handle)));
}

const ReferenceTarget = if (generated) @import("rx_execution_abi").layouts.@"zig:rx_project_host".ReferenceTarget else void;

pub fn typeDeclarationTarget(handle: *const anyopaque, row: ?u64) ReferenceTarget {
    return switch (borrow(handle).references.edges[@intCast(row.?)].target) {
        .source => .Source,
        .compiled => .Compiled,
        .native => .Native,
    };
}

pub fn typeDeclarationOwner(handle: *const anyopaque, row: ?u64) u64 {
    const edge = &borrow(handle).references.edges[@intCast(row.?)];

    return if (edge.target == .source) edge.target.source else 0;
}

pub fn publishTypeDeclaration(handle: *const anyopaque, index: ?u64, alias: []const u8) std.mem.Allocator.Error!void {
    try borrow(handle).publish(@intCast(index.?), Declarations.attribute(alias));
}

pub fn rejectTypeDeclaration(handle: *const anyopaque, at: []const u8, message: []const u8) Declarations.Error!void {
    return borrow(handle).fail(Declarations.attribute(at), message);
}

fn valueKind(kind: u8) bool {
    return kind == @backingInt(std.meta.Tag(zx.ir.Type).enumeration);
}
