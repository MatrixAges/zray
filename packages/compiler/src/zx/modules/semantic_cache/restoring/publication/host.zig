const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Artifact = @import("../../../artifact/model.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const result = @import("../../../link/result/host.zig");
const destination = @import("../../../link/signature/publication/destination.zig");
const verification = @import("../../../artifact/validation/view.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const Current = @import("../../restore.zig").Current;
const Restored = @import("../../restore.zig").Restored;
const TypeTail = @import("../../../../analysis/semantic/merging/publication/view.zig");
const scalar_rows = @import("../../../../analysis/type_table.zig").scalar_rows;
const restore_entry = @import("generated_semantic_restore");
const publish_entry = @import("generated_semantic_restore_publish");
const RestoreInput = std.meta.Child(restore_entry.Input);
const PublishInput = std.meta.Child(publish_entry.Input);
const Input = std.meta.Child(@FieldType(PublishInput, "views"));
const Body = std.meta.Child(@typeInfo(@FieldType(Input, "body")).optional.child);
const Control = @typeInfo(@FieldType(Input, "control")).optional.child;
const Stores = std.meta.Child(@FieldType(Input, "stores"));
const Attributes = std.meta.Child(@typeInfo(@FieldType(Input, "attributes")).optional.child);
const Table = std.meta.Child(@typeInfo(@FieldType(Input, "scalars")).optional.child);
const Destination = std.meta.Child(@FieldType(Input, "functions"));
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const Columns = std.meta.Child(@typeInfo(@FieldType(RestoreInput, "columns")).optional.child);
const Self = @This();

offsets: TypeTail.Offsets,
types: TypeTail,
scalars: Table,
body: remap.FunctionView(Body),
attributes: Attributes,
stores: Stores,
columns: Columns,
has_columns: bool,
surface: Surface(std.meta.Child(@FieldType(Input, "surface"))),
functions: destination.View(Destination),
empty: Empty,
validation: verification.View,
input: Input,
pub fn bind(self: *Self, frame: *@import("../run.zig").Frame) void {
    const module = frame.module;
    const target = frame.current;
    const source = if (module.function) |*value| value else null;

    var control_source: ?Control = null;

    self.surface.init(module.exports, module.constant_exports, .{ .mapped = &.{} });

    self.has_columns = source != null and !frame.decoded;

    if (source) |value| {
        const empty_nodes: Nodes = .{
            .allocator = frame.payload,
            .types = .{ .mapped = &.{} },
            .functions = .{ .indexed = &.{} },
            .native_modules = .{ .indexed = &.{} },
        };

        self.body.init(&empty_nodes, value, null);

        self.body.input.types = &self.surface.mapping;

        if (value.body.root != null) control_source = zx.columns.pointer(Control, value.body.control);

        self.attributes = .{
            .ownership = @fromBackingInt(@intCast(@backingInt(value.output_ownership))),
            .store_mode = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
            .root = if (value.body.root) |id| @backingInt(id) else null,
        };

        if (self.has_columns) self.columns = remap.functionColumns(Columns, value);
    }

    self.offsets = TypeTail.offsets(target.types);

    self.types.init(.{ .allocator = target.allocator, .payload = frame.payload, .types = target.types, .origins = &target.origins.items, .offsets = &self.offsets });

    const empty_types = target.types.count() == 0;

    if (empty_types) self.scalars = ir.TypeTable.borrow(Table, scalar_rows);

    self.stores = zx.columns.columns(Stores, module.stores);

    self.functions.init(&target.allocator, target.functions);

    self.empty = destination.empty(Empty);

    self.input = .{
        .body = if (source != null) &self.body.input else null,
        .control = control_source,
        .attributes = if (source != null) &self.attributes else null,
        .stores = &self.stores,
        .types = zx.columns.pointer(@FieldType(Input, "types"), @as(*const TypeTail.Target, &self.types.target)),
        .scalars = if (empty_types) &self.scalars else null,
        .reuse_store_types = if (source) |value| sameColumn(module.stores.types, value.stores.types) else false,
        .surface = &self.surface.input,
        .functions = &self.functions.input,
        .empty = &self.empty,
        .path = target.path,
    };
}

pub fn map(self: *Self, mappings: anytype) void {
    self.surface.mapping.dense = mappings.types;

    if (self.input.body != null) {
        self.body.input.candidate = mappings.candidate;
        self.body.functions.sparse = mappings.functions;
        self.body.natives.sparse = mappings.modules;
    }
}

pub fn finish(self: *const Self, target: *const Current, plan: anytype, verified: verification.Verified) Restored {
    target.verified.* = verification.applyPrefix(verified);

    const tables: result.Tables = .{
        .types = target.types.view(),
        .functions = target.functions.view(),
        .native_modules = target.native_modules,
    };

    return .{
        .program = result.fromPublication(target.path, plan, tables, self.surface.exports(), self.surface.constants()),
        .recursive = if (plan.recursive) |id| @fromBackingInt(id) else null,
    };
}

fn sameColumn(left: []const u32, right: []const u32) bool {
    return left.len == right.len and (left.len == 0 or left.ptr == right.ptr);
}
