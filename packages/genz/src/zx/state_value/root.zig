const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const scope = @import("scope.zig");
const generated = @import("genz_options").generated_analysis;
pub const Analysis = @import("analysis.zig");
pub const conversion = @import("conversion.zig");
const Cache = @import("../expression_map.zig").Map(ir.ExprId);

const Seed = struct {
    lowering: *Lower,
    types: []node.ExpressionId,
    layouts: []node.ExpressionId,
    cache: ?Cache,
    active: bool,
    pub fn restore(self: Seed) void {
        self.lowering.types = self.types;
        self.lowering.layouts = self.layouts;

        if (self.cache) |cache| self.lowering.cache = cache;

        self.lowering.state_active = self.active;
    }
};

const Represented = if (generated) scope.Frame(.Represented) else Seed;
const Borrowed = if (generated) scope.Frame(.Borrowed) else Seed;

pub fn enter(lowering: *Lower) Lower.Error!?Represented {
    if (!scope.applies(lowering, .Represented)) return null;
    if (generated) return try @import("entry.zig").enter(lowering);

    const saved: Seed = .{ .lowering = lowering, .types = lowering.types, .layouts = lowering.layouts, .cache = lowering.cache, .active = lowering.state_active };
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

    return saved;
}

pub fn enterBorrowed(lowering: *Lower) Borrowed {
    if (generated) return scope.enter(lowering, .Borrowed, .{ .state_active = false });

    const saved: Seed = .{ .lowering = lowering, .types = lowering.types, .layouts = lowering.layouts, .cache = null, .active = lowering.state_active };

    lowering.types = lowering.abi_types;
    lowering.layouts = lowering.abi_layouts;
    lowering.state_active = false;

    return saved;
}

pub fn selected(lowering: *const Lower, id: ir.TypeId) bool {
    return lowering.state_active and lowering.state_plan.selected[@backingInt(id)];
}
