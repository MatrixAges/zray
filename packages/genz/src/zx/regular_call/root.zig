const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const seed = @import("seed.zig");
const value = @import("../value_call/root.zig");

pub fn lower(self: *Lower, invocation: seed.Operation) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return seed.lower(self, invocation);

    const selected = @import("policy.zig").analyze(self, invocation);

    return switch (selected.route) {
        .Value => value.invocation(self, invocation),
        .Pointer => value.pointerInvocation(self, invocation),
        .Regular => @import("../invocation/execute.zig").regular(self, invocation, selected.regular.?),
    };
}
