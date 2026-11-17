const std = @import("std");
const ir = @import("zx").ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Module = @import("../../../artifact/model.zig").Module;
const Error = @import("../../../artifact/model.zig").Error;
const Placement = @import("../../dependencies/host.zig").Placement;

pub fn publish(nodes: *Nodes, module: *const Module, storage: *ir.FunctionStorage, temporary: std.mem.Allocator, linked: *?ir.FunctionId, placement: Placement, comptime entry: bool) Error!?Nodes.FunctionEntry {
    const first = storage.count();

    return switch (placement) {
        .Absent => null,
        .Append => published: {
            try nodes.appendFunction(storage, &module.function.?, temporary);

            linked.* = @fromBackingInt(@intCast(first));

            break :published null;
        },
        .Retain => try nodes.functionEntry(module.function.?, if (entry) @fromBackingInt(@intCast(first)) else null, .unchecked),
        .Invalid, .Conflict, .Full => unreachable,
    };
}
