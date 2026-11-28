pub const expression = @import("expression.zig");
pub const call = @import("call.zig");
pub const module = @import("module.zig");
pub const project = @import("project.zig");
pub const store = @import("store.zig");
pub const gateway = @import("gateway.zig");
const imports = @import("project/mixed/imports.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @This(),
    @import("rx").graph_registration,
    @import("inference/construction/object.zig"),
    @import("inference/fields/host.zig"),
    @import("inference/fields/replay.zig"),
    @import("inference/object_closure/host.zig"),
    @import("inference/object_closure/replay.zig"),
    @import("inference/resolve/host.zig"),
    @import("inference/selection/host.zig"),
    @import("inference/unify/host.zig"),
    @import("program/statements/traversal/call.zig"),
    @import("project/constraints/collection/host.zig"),
    @import("project/flow/traversal/host.zig"),
    @import("condition.zig"),
    @import("project/workflow/derive/host.zig"),
    @import("project/workflow/infer/host.zig"),
    @import("project/workflow/solve/host.zig"),
}).resolve;
