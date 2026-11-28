const std = @import("std");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const entry = @import("generated_run_list_update");
const Self = @This();
pub const View = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));
const State = std.meta.Child(View);
const Request = std.meta.Child(@FieldType(State, "request"));

lowering: *Lower,
sequence: *Sequence,

state: State = .{ .request = null, .result = 0 },

pub const Host = struct {
    work: *Self,
    store_0: *const View,
    pub fn commit(self: Host, pending: anytype) Lower.Error!void {
        try self.work.runCollectionWork(pending.store_0);
    }
};

pub fn runCollectionWork(self: *Self, pending: ?View) Lower.Error!void {
    const state = pending orelse return;

    self.state.result = try self.resolve(state.request orelse unreachable);
}

fn resolve(self: *Self, request: Request) Lower.Error!u32 {
    const lowering = self.lowering;
    const sequence = self.sequence;

    if (request.target) |target| return @backingInt(try lowering.expr(@fromBackingInt(target)));

    if (request.clip) |clip| return @backingInt(try @import("../state_value/ownership.zig").clip(
        lowering,
        sequence,
        @fromBackingInt(clip.target),
        @fromBackingInt(clip.value),
    ));

    if (request.pop) |pop| return @backingInt(try @import("pop.zig").lower(lowering, sequence, .{
        .type_id = @fromBackingInt(pop.source_type),
        .result_type = @fromBackingInt(pop.result_type),
        .items = @fromBackingInt(pop.items),
        .value = @fromBackingInt(pop.value),
        .header = @fromBackingInt(pop.header),
        .element = @fromBackingInt(pop.element),
        .length = @fromBackingInt(pop.length),
        .retract = pop.retract,
    }));

    const construct = request.construct orelse unreachable;

    return @backingInt(try @import("../construction/build.zig").lower(
        lowering,
        @fromBackingInt(construct.type_id),
        @fromBackingInt(construct.value),
        if (construct.layout) |layout| @fromBackingInt(layout) else null,
    ));
}
