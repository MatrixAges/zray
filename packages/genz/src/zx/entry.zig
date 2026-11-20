const Lower = @import("lower.zig");
const emit = @import("entry/emitting.zig");

pub fn declarations(lowering: *Lower, output: *@import("../node/declarations.zig").Output) Lower.Error!void {
    if (!emit.generated) return @import("entry/seed.zig").declarations(lowering, output);

    const route = @import("entry/policy.zig").base(lowering);
    var inner = try lowering.function(route.name, route.exported);

    inner.function.exported = true;

    try output.append(lowering.allocator, inner);
    if (route.forward) try output.append(lowering.allocator, try emit.arena(lowering, inner.function));
}
