const std = @import("std");
const ir = @import("zx").ir;
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Memo = @import("../memo.zig");
const layers = @import("layers/root.zig");
const Error = std.mem.Allocator.Error;

const Request = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    program: *const ir.Program,
    slots: Slots,
    texts: []const bool,
    contents: []const Memo.Digest,
    types: Memo.Digest,
    memo: ?*Memo,
};

pub fn solve(request: Request) Error!Flow {
    const result = try @import("initial.zig").create(request.allocator, request.program.*, request.slots, request.texts);
    const maybe_plan = try layers.build(request.temporary, &request.program.functions, result.held, request.memo != null);

    if (maybe_plan == null) {
        try @import("fixpoint.zig").settle(result, request.temporary, request.workspace, &request.program.functions, request.slots);

        return result;
    }

    const plan = maybe_plan.?;

    const remembered = if (request.memo) |memo|
        try Flow.Remembered.init(request.temporary, memo, request.types, request.contents, request.program.functions.count())
    else
        null;

    if (plan.order.len != 0) {
        const walkers = try Flow.Walker.open();

        defer Flow.Walker.close(walkers);

        var first: usize = 0;

        for (plan.ends) |raw_end| {
            const end: usize = @intCast(raw_end);

            var layer: Flow.Layer = .{
                .flow = result,
                .table = &request.program.functions,
                .slots = request.slots,
                .functions = plan.order[first..end],
                .walkers = walkers,
                .remembered = remembered,
            };

            try layer.spread();

            if (remembered) |kept| {
                for (plan.order[first..end]) |body_u32| {
                    const body: usize = body_u32;

                    if (kept.found[body]) {
                        kept.memo.keepFlowed(kept.keys[body]);
                    } else {
                        try kept.memo.putFlowed(kept.keys[body], result.held[body], result.text_held[body], result.written[body]);
                    }
                }
            }

            first = end;
        }
    }

    return result;
}
