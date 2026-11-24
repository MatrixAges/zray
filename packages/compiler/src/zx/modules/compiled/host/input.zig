const std = @import("std");
const ir = @import("zx").ir;
const memory = @import("zx").memory;
const model = @import("../../compiled.zig");
const load = @import("../load.zig");
const Origins = @import("../../nominal_origins.zig");
const borrow = @import("../../../ir/canonical/borrow.zig");
const generated = @import("generated_compiled_library");
const Request = std.meta.Child(generated.Input);
const Input = std.meta.Child(@FieldType(Request, "plan"));
const Graph = std.meta.Child(@FieldType(Input, "graph"));
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Selection = std.meta.Child(@typeInfo(@FieldType(Input, "selection")).optional.child);
const selection_fields = .{ .names = "name", .modules = "module" };
const Self = @This();

graph: @import("graph.zig").View(Graph),
types: std.meta.Child(@FieldType(Destination, "types")),
base_origins: std.meta.Child(@FieldType(Destination, "origins")),
natives: std.meta.Child(@FieldType(Destination, "natives")),
destination: Destination,
selection: Selection,
selection_rows: memory.ReadFields(selection_fields),
type_ids: []u32,
export_buckets: []u64,
input: Input,
pub fn init(self: *Self, allocator: std.mem.Allocator, graph: *const model.Graph, instance: []const u8, artifact: []const u8, destination: load.Destination, seed: bool, selected: ?[]const model.PublicReference, export_buckets: ?[]u64) void {
    self.graph.init(allocator, graph);

    const origins = destination.origins.items.view();

    self.types = ir.TypeTable.borrow(@TypeOf(self.types), destination.types.view());
    self.base_origins = Origins.Table.borrow(@TypeOf(self.base_origins), origins);
    self.natives = borrow.columns(@TypeOf(self.natives), destination.native_modules.view());
    self.destination = .{ .types = &self.types, .origins = &self.base_origins, .origin_names = origins.names, .natives = &self.natives, .function_count = destination.functions.count() };

    if (selected) |values| {
        self.selection_rows = memory.borrowReadFields(selection_fields, values);
        self.selection = self.selection_rows.bind(Selection);
    }

    self.type_ids = &.{};
    self.export_buckets = export_buckets orelse &.{};

    self.input = .{
        .graph = &self.graph.input,
        .export_index = @ptrCast(&self.export_buckets),
        .instance = instance,
        .artifact = artifact,
        .seed = seed,
        .destination = &self.destination,
        .type_mapping = @ptrCast(&self.type_ids),
        .selection = if (selected != null) &self.selection else null,
    };
}
