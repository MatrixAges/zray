const Route = @import("../unification/plan.zig").Route;

pub fn shape(route: Route) []const u8 {
    return switch (route) {
        .SequenceMismatch => "a sequence requires a list or tuple type",
        .ShapeMismatch => "incompatible inferred input shapes",
        .TupleMismatch => "incompatible inferred tuple lengths",
        .ConcreteMismatch => "input uses require different concrete types",
        .ConcreteObjectMismatch => "input object requirements conflict with its complete type",
        .ConcreteContainerMismatch => "input container requirements conflict with its complete type",
        .ConcreteTupleMismatch => "input tuple requirements conflict with its complete type",
        else => unreachable,
    };
}
