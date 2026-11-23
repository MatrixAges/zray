const Flow = @import("../flow.zig");
const generated = @import("rx_options").generated_graph;
const seed = @import("traversal/seed.zig");
const host = @import("traversal/host.zig");
pub const Region = if (generated) @FieldType(host.View, "region") else seed.Region;

pub const Cursor = struct {
    first: usize,
    end: usize,
    pub fn body(unit: Flow.Unit) Cursor {
        return .{ .first = unit.first, .end = @as(usize, unit.first) + unit.count };
    }
    pub fn cases(count: usize) Cursor {
        return .{ .first = 0, .end = count };
    }
};

pub fn run(state: anytype, plan: *const Flow.Plan) @TypeOf(state.closeCase(true)) {
    if (comptime generated) return host.run(state, plan);

    return seed.run(state, plan);
}
