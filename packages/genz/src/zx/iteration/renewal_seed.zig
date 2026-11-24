const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const renew = @import("../growth/renew_seed.zig").renew;
const Target = @import("../growth/delivery.zig").Target;

pub fn needsEntries(lowering: *const Lower, owner: ir.ExprId) bool {
    for (lowering.plan.renewals) |record| {
        if (record.owner == @backingInt(owner) and !record.value) return true;
    }

    return false;
}

pub fn store(lowering: *Lower, owner: ir.ExprId, type_id: ir.TypeId, target: Target) Lower.Error!node.Block {
    var body: std.ArrayList(node.Statement) = .empty;

    for (lowering.plan.renewals) |record| {
        if (record.owner != @backingInt(owner) or record.value) continue;

        const reference = switch (target) {
            .reference => |value| value,
            .name => |name| try lowering.builder.identifier(name),
        };

        try renew(lowering, &body, type_id, reference, record.path, record.writable);
    }

    return lowering.builder.statements(body.items);
}
