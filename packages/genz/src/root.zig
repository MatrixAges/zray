pub const import_module = @import("node/import_module.zig");
pub const node = @import("node.zig");
pub const Builder = @import("builder.zig");
pub const render = @import("render.zig").render;
pub const render_module = @import("printer/module.zig");
pub const zx = @import("zx/render.zig");
pub const gateway = @import("gateway/root.zig");
pub const host = @import("host/root.zig");
const flow = @import("zx/uniqueness/flow.zig");
const read = @import("zx/expressions/read.zig");
const publication = @import("zx/state_value/publication.zig");
const object_execution = @import("zx/aggregate/object_execution.zig");
const contracts = @import("zx/contracts.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @This(),
    @import("node/direct.zig"),
    @import("zx/aggregate/object_execution.zig"),
    @import("zx/aggregate/sequence.zig"),
    @import("zx/contracts.zig"),
    @import("zx/collections/workflow.zig"),
    @import("zx/collections/branch.zig"),
    @import("zx/expressions/evaluate/native.zig"),
    @import("zx/expressions/read.zig"),
    @import("zx/function_analysis/workflow.zig"),
    @import("zx/functions/body.zig"),
    @import("zx/functions/value.zig"),
    @import("zx/construction/publication.zig"),
    @import("zx/list_update.zig"),
    @import("zx/invocation/execute.zig"),
    @import("zx/invocation/publication.zig"),
    @import("zx/iteration/assignment.zig"),
    @import("zx/iteration/execution/emission.zig"),
    @import("zx/iteration/execution/frame.zig"),
    @import("zx/iteration/execution/prepare.zig"),
    @import("zx/iteration/fields/ownership.zig"),
    @import("zx/iteration/fields/publication.zig"),
    @import("zx/iteration/frame.zig"),
    @import("zx/iteration/result.zig"),
    @import("zx/iteration/state.zig"),
    @import("zx/iteration_consumer/execute.zig"),
    @import("zx/iteration_consumer/read.zig"),
    @import("zx/iteration_layout/select.zig"),
    @import("zx/iteration_value/invocation.zig"),
    @import("zx/iteration_value/mutation.zig"),
    @import("zx/iteration_value/operands.zig"),
    @import("zx/iteration_value/projection_emission.zig"),
    @import("zx/iteration_value/publication.zig"),
    @import("zx/iteration_value/resources.zig"),
    @import("zx/match.zig"),
    @import("zx/module/execution/emission.zig"),
    @import("zx/module/execution/frame.zig"),
    @import("zx/module/execution/function.zig"),
    @import("zx/module/execution/requests.zig"),
    @import("zx/modules/signature/execution.zig"),
    @import("zx/predicates.zig"),
    @import("zx/regular_call/root.zig"),
    @import("zx/scope/execute.zig"),
    @import("zx/simd/emission.zig"),
    @import("zx/sorting/root.zig"),
    @import("zx/sorting/worker.zig"),
    @import("zx/state_value/entry.zig"),
    @import("zx/state_value/publication.zig"),
    @import("zx/statements/emit.zig"),
    @import("zx/statements/traversal/host.zig"),
    @import("zx/tasks/parallel.zig"),
    @import("zx/transform/collect.zig"),
    @import("zx/transform/execution.zig"),
    @import("zx/transform/publication.zig"),
    @import("zx/transform/reduce.zig"),
    @import("zx/uniqueness/basis.zig"),
    @import("zx/uniqueness/flow.zig"),
    @import("zx/uniqueness/flow/execution.zig"),
    @import("zx/uniqueness/flow/fixpoint.zig"),
    @import("zx/uniqueness/identity.zig"),
    @import("zx/uniqueness/program/driver.zig"),
    @import("zx/value_call/argument.zig"),
    @import("zx/value_call/argument_object.zig"),
}).resolve;
