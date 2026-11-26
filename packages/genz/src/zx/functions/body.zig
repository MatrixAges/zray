const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const stores = @import("../store/transaction.zig");
const signature = @import("../signature/build.zig");
const prelude = @import("prelude/build.zig");
const Error = Lower.Error;

pub fn lower(self: *Lower, name: []const u8, exported: bool) Error!node.Declaration {
    const errors = try @import("../error_effects.zig").program(self);
    const flags: prelude.Flags = .{ .exported = exported, .io = self.entry_flags.io, .process = self.entry_flags.process };

    try @import("context.zig").prepare(self, errors);

    const stmts = try self.statements(self.program.body.block());
    const contracts = try @import("../contracts.zig").preconditions(self);
    const before = try prelude.lower(self, flags);
    const has_stores = self.program.stores.count() != 0;
    const pending: node.Block = if (has_stores) try stores.initialize(self) else .{};
    const references = try self.referenceBlock();
    const commit: node.Block = if (has_stores) try stores.finish(self) else .{};
    var request: signature.Request = .{ .name = name, .exported = exported, .errors = errors };
    var declaration = try signature.build(self, &request);
    const ordered = [_]node.Block{ before, pending, references, contracts, stmts, commit };
    var starts: [ordered.len]u32 = undefined;
    var lengths: [ordered.len]u32 = undefined;

    for (ordered, &starts, &lengths) |block, *start, *length| {
        start.* = block.start;
        length.* = block.len;
    }

    declaration.body = try blocks.join(self.allocator, self.builder.nodes, &starts, &lengths);

    return .{ .function = declaration };
}
