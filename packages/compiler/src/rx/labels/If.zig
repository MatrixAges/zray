const std = @import("std");
const dsl = @import("dsl");
const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const steps = @import("../steps.zig");
const Else = @import("Else.zig").Else;

const IfBase = schema.element("If", struct { on: []const u8 }, schema.list(struct {
    pub const Data = union(enum) { step: steps.Step, @"else": Else.Data };

    pub fn decode(allocator: std.mem.Allocator, input: anytype, reporter: *dsl.Reporter, context: anytype) dsl.Error!Data {
        const node = dsl.ast.view(input);

        if (Else.matches(node.name())) return .{ .@"else" = try Else.decode(allocator, input, reporter, context) };

        return .{ .step = try steps.child(.Body).decode(allocator, input, reporter, context) };
    }
}, .{ .min = 1 }));

pub const If = dsl.refineAlloc(IfBase, checkIf);

fn checkIf(allocator: std.mem.Allocator, data: IfBase.Data, input: anytype, _: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);

    try checks.validate(.Common, data.attributes, node, reporter);

    return @import("../schema/selection/adapter.zig").checkIf(allocator, node, reporter);
}
