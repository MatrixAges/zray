const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const plan = @import("adapter/plan.zig");
const scope = @import("../state_value/scope.zig");
const generated = @import("genz_options").generated_analysis;

pub fn build(self: *Lower, id: ir.FunctionId) Lower.Error!?node.Declaration {
    if (!plan.eligible(self, id)) return null;

    const errors = try @import("../error_effects.zig").program(self);
    const argument = plan.argument(self, errors orelse &.{}) orelse return null;
    const saved = scope.enter(self, .Adapter, .{ .cache = .empty, .plan = .{ .flags = &.{} } });

    defer saved.restore();

    @import("context.zig").reset(self, .Adapter);

    if (generated) {
        try @import("context.zig").clear(self);
    } else {
        @memset(self.used, false);
        @memset(self.cache_reads, 0);
    }

    self.used[0] = true;

    try self.cache.put(self.allocator, argument, try self.builder.identifier("in"));

    const result = try @import("../value_call/root.zig").pointerInvocation(self, .{
        .function = id,
        .argument = argument,
        .stores = &.{},
    });

    const prelude = try @import("prelude/build.zig").lower(self, .{ .exported = false, .io = false, .process = false });
    const references = try self.referenceBlock();
    const returned = try self.builder.statements(&.{.{ .result = result }});
    var function = try self.prototype("call", false);

    function.body = try @import("../../node/blocks.zig").join(
        self.allocator,
        self.builder.nodes,
        &.{ prelude.start, references.start, returned.start },
        &.{ prelude.len, references.len, returned.len },
    );

    return .{ .function = function };
}
