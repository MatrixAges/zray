const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const types = @import("types.zig");
const StoredTable = @import("../state_value/element_emission.zig").StoredTable;

pub fn materializeType(frame: *anyopaque, id: u32, representation: evaluation.Api.StoredType) Lower.Error!u32 {
    const self = evaluation.borrow(frame);
    const type_id: ir.TypeId = @fromBackingInt(id);

    return @backingInt(switch (representation) {
        .IterationType => try types.get(self.iteration_resources.?.context, type_id),
        .IterationItem => try types.get(self.iteration_resources.?.context, self.program.typeOf(type_id).list),
        .Layout => try self.layoutExpr(type_id),
        inline else => |kind| try @import("../types.zig").resource(
            self,
            type_id,
            @field(StoredTable, @tagName(kind)),
        ),
    });
}
