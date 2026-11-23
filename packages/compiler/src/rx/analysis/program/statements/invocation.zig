const zx = @import("zx");
const ir = zx.ir;
const Module = @import("../../module.zig");
const Builder = @import("../builder.zig");
pub const Import = @import("../linking/import.zig");
const write_call = @import("../linking/call/host.zig");
const generated = @import("rx_options").generated_graph;
const Self = @This();

call: *const Module.Call,
argument: ir.ExprId = undefined,
stores: []u32 = undefined,
function: Import = undefined,
pub fn resolveStores(self: *Self, builder: *Builder) Builder.Error!void {
    const slots = self.call.callee.stores;

    if (comptime generated) {
        self.stores = try write_call.prepare(builder, slots.count());

        try @import("../store/bind.zig").write(builder, slots, self.stores);
    } else {
        self.stores = try builder.allocator.alloc(u32, slots.count());

        for (self.stores, 0..) |*mapped, index| mapped.* = try builder.seedStore(slots.at(index));
    }
}

pub fn emit(self: *const Self, builder: *Builder) Builder.Error!ir.ExprId {
    const function = self.function.id;

    return if (self.call.loop) |loop|
        try @import("../linking/call/loop.zig").lower(builder, function, self.argument, self.stores, loop)
    else
        try write_call.invoke(builder, function, self.argument, self.call.callee.output_type, self.stores);
}
