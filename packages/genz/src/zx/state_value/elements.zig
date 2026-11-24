const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("elements_seed.zig");
const operations = if (generated) @import("element_emission.zig") else seed;
const Statements = if (generated) @import("../../node/blocks.zig").Sequence else std.ArrayList(node.Statement);
pub const inlineStored = operations.inlineStored;
pub const typeExpr = operations.typeExpr;
pub const read = operations.read;
pub const write = operations.write;
pub const captureName = operations.captureName;
pub const convert = seed.convert;

pub fn expression(self: *Lower, list: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    var body: Statements = if (generated) self.builder.statementSequence(self.workspace) else .empty;

    defer if (generated) body.deinit();

    const element = try read(self, &body, list, value);

    return @import("../aggregate.zig").finish(self, &body, element);
}
