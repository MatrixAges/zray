const std = @import("std");
const ir = @import("zx").ir;
const memory = @import("zx").memory;
const model = @import("../../compiled.zig");
const load = @import("../load.zig");
const Origins = @import("../../nominal_origins.zig");
const borrow = @import("../../../ir/canonical/borrow.zig");
const generated = @import("generated_compiled_library");
const Input = std.meta.Child(generated.Input);
const Graph = std.meta.Child(@FieldType(Input, "graph"));
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Selection = std.meta.Child(@typeInfo(@FieldType(Input, "selection")).optional.child);
const Self = @This();

graph: @import("graph.zig").View(Graph),
types: std.meta.Child(@FieldType(Destination, "types")),
base_origins: std.meta.Child(@FieldType(Destination, "origins")),
natives: std.meta.Child(@FieldType(Destination, "natives")),
destination: Destination,
selection: Selection,
selection_names: memory.TextColumn,
selection_modules: memory.TextColumn,
type_ids: []u32,
input: Input,
pub fn init(self: *Self, allocator: std.mem.Allocator, graph: *const model.Graph, instance: []const u8, artifact: []const u8, destination: load.Destination, seed: bool, selected: ?[]const model.PublicReference) std.mem.Allocator.Error!void {
    self.graph.init(allocator, graph);

    const origins = destination.origins.items.view();

    self.types = ir.TypeTable.borrow(@TypeOf(self.types), destination.types.view());
    self.base_origins = Origins.Table.borrow(@TypeOf(self.base_origins), origins);
    self.natives = borrow.columns(@TypeOf(self.natives), destination.native_modules.view());
    self.destination = .{ .types = &self.types, .origins = &self.base_origins, .origin_names = origins.names, .natives = &self.natives, .function_count = destination.functions.count() };

    if (selected) |values| {
        self.selection_names = memory.borrowTextColumn("name", values);
        self.selection_modules = memory.borrowTextColumn("module", values);

        self.selection = .{
            .names = @ptrCast(&self.selection_names),
            .modules = @ptrCast(&self.selection_modules),
            .count = values.len,
        };
    }

    self.type_ids = try allocator.alloc(u32, graph.program.types.count());

    @memset(self.type_ids, 0);

    self.input = .{
        .graph = &self.graph.input,
        .instance = instance,
        .artifact = artifact,
        .seed = seed,
        .destination = &self.destination,
        .type_ids = self.type_ids,
        .type_mapping = @ptrCast(&self.type_ids),
        .selection = if (selected != null) &self.selection else null,
    };
}
