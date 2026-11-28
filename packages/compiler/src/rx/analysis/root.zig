pub const expression = @import("expression.zig");
pub const call = @import("call.zig");
pub const module = @import("module.zig");
pub const project = @import("project.zig");
pub const store = @import("store.zig");
pub const gateway = @import("gateway.zig");
const imports = @import("project/mixed/imports.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @import("project/prepare/modules/host.zig"),
    @This(),
    @import("rx").graph_registration,
    @import("inference/assignment/application/host.zig"),
    @import("inference/assignment/registration/host.zig"),
    @import("inference/construction/object.zig"),
    @import("inference/fields/host.zig"),
    @import("inference/fields/replay.zig"),
    @import("inference/index/host.zig"),
    @import("inference/known/host.zig"),
    @import("inference/object_closure/host.zig"),
    @import("inference/object_closure/replay.zig"),
    @import("inference/optional/host.zig"),
    @import("inference/projections/host.zig"),
    @import("inference/resolve/host.zig"),
    @import("inference/selection/host.zig"),
    @import("inference/sequences/host.zig"),
    @import("inference/solve/host.zig"),
    @import("inference/unify/host.zig"),
    @import("program/statements/traversal/call.zig"),
    @import("program/statements/traversal/host.zig"),
    @import("project/constraints/collection/host.zig"),
    @import("project/flow/traversal/host.zig"),
    @import("condition.zig"),
    @import("project/mixed/state.zig"),
    @import("project/workflow/derive/host.zig"),
    @import("project/workflow/infer/host.zig"),
    @import("project/workflow/solve/host.zig"),
}).resolve;
