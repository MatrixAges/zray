const std = @import("std");
const memory = @import("zx").memory;
const model = @import("../../compiled.zig");
const Origins = @import("../../nominal_origins.zig");
const initializer_fields = .{ .identities = "identity", .versions = "schema_version", .functions = "function" };

pub fn View(comptime Graph: type) type {
    return struct {
        program: @import("../../../ir/canonical/validation/input.zig").Storage(std.meta.Child(@FieldType(Graph, "program"))),
        origins: std.meta.Child(@FieldType(Graph, "origins")),
        exports: @import("input/exports.zig").View(std.meta.Child(@FieldType(Graph, "exports"))),
        initializer_rows: memory.ReadFields(initializer_fields),
        initializers: std.meta.Child(@FieldType(Graph, "initializers")),
        input: Graph,
        pub fn init(self: *@This(), allocator: std.mem.Allocator, graph: *const model.Graph) void {
            self.program.init(allocator, &graph.program, .{});

            self.origins = Origins.Table.borrow(@TypeOf(self.origins), graph.nominal_types);

            self.exports.init(graph.exports);

            self.initializer_rows = memory.borrowReadFields(initializer_fields, graph.store_initializers);
            self.initializers = self.initializer_rows.bind(@TypeOf(self.initializers));

            self.input = .{
                .program = &self.program.input,
                .origins = &self.origins,
                .origin_names = graph.nominal_types.names,
                .exports = &self.exports.input,
                .initializers = &self.initializers,
            };
        }
    };
}
