const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub fn lower(self: *Lower) Lower.Error!node.Block {
    var statements: std.ArrayList(node.Statement) = .empty;
    const contracts = self.program.contracts;

    for (contracts.kinds, 0..) |kind, index| {
        if (kind != .Requires) continue;

        const contract = contracts.at(index);
        var predicate = try open(self, &contract);
        const value = try predicate.expr(contract.predicate);
        const failure = try self.builder.expression(.{ .unary = .{ .operator = .not, .operand = value } });

        try @import("../intrinsics.zig").failIf(self, &statements, failure, "PreconditionFailed");

        self.used[0] = self.used[0] or predicate.used[0];
        self.uses_allocator = self.uses_allocator or predicate.uses_allocator;
        self.uses_io = self.uses_io or predicate.uses_io;
        self.serial = predicate.serial;
        self.reference_storage = predicate.reference_storage;
    }

    return self.builder.finishStatements(&statements);
}

fn open(self: *Lower, contract: *const zx.ir.Contract) Lower.Error!Lower {
    var predicate = self.*;
    predicate.state_symbols = self.state_symbols.inherit();
    predicate.program.symbols = contract.symbols;
    predicate.program.expressions = contract.expressions;

    try predicate.refreshEntry();

    predicate.names = try self.allocator.dupe([]const u8, &.{"in"});
    predicate.used = try self.allocator.alloc(bool, 1);
    predicate.cache_reads = try self.allocator.alloc(u64, contract.expressions.count());
    predicate.cache = .empty;
    predicate.stack_symbols = .empty;
    predicate.uses_allocator = false;
    predicate.uses_io = false;

    @memset(predicate.used, false);
    @memset(predicate.cache_reads, 0);

    return predicate;
}
