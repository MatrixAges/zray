const std = @import("std");
const model = @import("../../compiled.zig");
const Origins = @import("../../nominal_origins.zig");

pub fn View(comptime Graph: type) type {
    return struct {
        program: @import("../../../ir/canonical/validation/input.zig").Storage(std.meta.Child(@FieldType(Graph, "program"))),
        origins: std.meta.Child(@FieldType(Graph, "origins")),
        exports: @import("input/exports.zig").View(std.meta.Child(@FieldType(Graph, "exports"))),
        initializers: @import("input/initializers.zig").View(std.meta.Child(@FieldType(Graph, "initializers"))),
        input: Graph,
        pub fn init(self: *@This(), allocator: std.mem.Allocator, graph: *const model.Graph) void {
            self.program.init(allocator, &graph.program, .{});

            self.origins = Origins.Table.borrow(@TypeOf(self.origins), graph.nominal_types);

            self.exports.init(graph.exports);
            self.initializers.init(graph.store_initializers);

            self.input = .{
                .program = &self.program.input,
                .origins = &self.origins,
                .origin_names = graph.nominal_types.names,
                .exports = &self.exports.input,
                .initializers = &self.initializers.input,
            };
        }
    };
}
