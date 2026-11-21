const zx = @import("zx");
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const stores = @import("../store/transaction.zig");
const prelude = @import("prelude/build.zig");
const entry = @import("generated_function_body_workflow");

const Spans = struct {
    statements: node.Block,
    contracts: node.Block,
    prelude: node.Block,
    pending: node.Block = .{},
    references: node.Block,
    commit: node.Block = .{},
};

pub fn lower(self: *Lower, name: []const u8, exported: bool) Lower.Error!node.Declaration {
    return if (self.program.stores.count() != 0) build(self, name, exported, .Store) else build(self, name, exported, .Plain);
}

fn build(self: *Lower, name: []const u8, exported: bool, comptime form: entry.Input) Lower.Error!node.Declaration {
    var spans: Spans = .{ .statements = undefined, .contracts = undefined, .prelude = undefined, .references = undefined };
    var errors: ?[]const []const u8 = undefined;
    var declaration: node.Function = undefined;
    var flags: prelude.Flags = undefined;

    inline for (comptime zx.staticSequence(entry, form)) |step| switch (step) {
        .Errors => {
            errors = try @import("../error_effects.zig").program(self);
            flags = .{ .exported = exported, .io = self.entry_flags.io, .process = self.entry_flags.process };
        },
        .Workspace => try @import("context.zig").prepare(self, errors),
        .Statements => spans.statements = try self.statements(self.program.body.block()),
        .Contracts => spans.contracts = try @import("../contracts.zig").preconditions(self),
        .Prelude => spans.prelude = try prelude.lower(self, flags),
        .Pending => spans.pending = try stores.initialize(self),
        .References => spans.references = try self.referenceBlock(),
        .Commit => spans.commit = try stores.finish(self),
        .Signature => declaration = try @import("../signature/build.zig").build(self, name, exported, errors),
    };

    declaration.body = try assemble(self, spans);

    return .{ .function = declaration };
}

fn assemble(self: *Lower, spans: Spans) Lower.Error!node.Block {
    const order = comptime zx.staticSequence(entry, .Layout);
    var starts: [order.len]u32 = undefined;
    var lengths: [order.len]u32 = undefined;

    inline for (order, &starts, &lengths) |step, *start, *length| {
        const block = switch (step) {
            .Prelude => spans.prelude,
            .Pending => spans.pending,
            .References => spans.references,
            .Contracts => spans.contracts,
            .Statements => spans.statements,
            .Commit => spans.commit,
            else => @compileError("Build step in function body layout"),
        };

        start.* = block.start;
        length.* = block.len;
    }

    return blocks.join(self.allocator, self.builder.nodes, &starts, &lengths);
}
