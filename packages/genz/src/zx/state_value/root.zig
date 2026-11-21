const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
pub const Analysis = @import("analysis.zig");
pub const conversion = @import("conversion.zig");
const Self = @This();
const Cache = @import("../expression_map.zig").Map(ir.ExprId);

pub const Saved = struct {
    types: []node.ExpressionId,
    layouts: []node.ExpressionId,
    cache: ?Cache,
    active: bool,
};

lowering: *Lower,
previous: ?Saved,
pub fn enter(lowering: *Lower) Lower.Error!Self {
    if (@import("genz_options").generated_analysis) return @import("entry.zig").enter(lowering, .represented);
    if (lowering.state_active) return .{ .lowering = lowering, .previous = null };

    const saved: Saved = .{ .types = lowering.types, .layouts = lowering.layouts, .cache = lowering.cache, .active = lowering.state_active };
    var cache: Cache = .empty;
    var entries = saved.cache.?.state.iterator();

    while (entries.next()) |entry| {
        var body: std.ArrayList(node.Statement) = .empty;
        const value = try conversion.convert(lowering, &body, lowering.program.expression(entry.key_ptr.*).type_id, entry.value_ptr.*, .value);

        try cache.put(lowering.allocator, entry.key_ptr.*, try @import("../aggregate.zig").finish(lowering, &body, value));
    }

    lowering.cache = cache;
    lowering.types = lowering.state_types;
    lowering.layouts = lowering.state_layouts;
    lowering.state_active = true;

    return .{ .lowering = lowering, .previous = saved };
}

pub fn enterBorrowed(lowering: *Lower) Lower.Error!Self {
    if (@import("genz_options").generated_analysis) return @import("entry.zig").enter(lowering, .borrowed);

    const saved: Saved = .{ .types = lowering.types, .layouts = lowering.layouts, .cache = null, .active = lowering.state_active };

    lowering.types = lowering.abi_types;
    lowering.layouts = lowering.abi_layouts;
    lowering.state_active = false;

    return .{ .lowering = lowering, .previous = saved };
}

pub fn restore(self: Self) void {
    const previous = self.previous orelse return;

    self.lowering.types = previous.types;
    self.lowering.layouts = previous.layouts;

    if (previous.cache) |cache| self.lowering.cache = cache;

    self.lowering.state_active = previous.active;
}

pub fn selected(lowering: *const Lower, id: ir.TypeId) bool {
    return lowering.state_active and lowering.state_plan.selected[@backingInt(id)];
}
