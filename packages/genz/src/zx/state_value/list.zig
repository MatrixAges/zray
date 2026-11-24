const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const seed = @import("list_seed.zig");
pub const Storage = seed.Storage;

pub fn selected(self: *const Lower, id: ir.TypeId) bool {
    if (!@import("genz_options").generated_analysis) return seed.selected(self, id);

    const generated = @import("generated_state_list_selected");
    const Input = std.meta.Child(generated.Input);
    const index = @backingInt(id);

    const input: Input = .{
        .active = self.state_active,
        .chosen = if (self.state_active) self.state_plan.selected[index] else false,
        .kind = if (self.state_active) self.program.types.kinds[index] else 0,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return @import("zx").columns.invoke(generated.executeValue, fixed.allocator(), &input) catch unreachable;
}

const representation = if (@import("genz_options").generated_analysis) @import("list_emission.zig") else seed;
pub const tag = representation.tag;
pub const headered = representation.headered;
pub const exclusive = representation.exclusive;
pub const writable = representation.writable;
pub const weakened = representation.weakened;
pub const create = representation.create;
pub const proven = representation.proven;
pub const owned = representation.owned;
pub const borrowed = representation.borrowed;
pub const items = representation.items;
pub const wrap = representation.wrap;
pub const reserve = seed.reserve;

pub fn expression(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    return items(self, self.program.expression(id).type_id, try self.expr(id));
}
