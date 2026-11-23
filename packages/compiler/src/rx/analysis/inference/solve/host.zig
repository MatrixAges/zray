const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Bindings = @import("../bindings/host.zig");
const generated = @import("rx_options").generated_graph;
const NonNull = @import("../non_null/host.zig");
const ObjectClosure = @import("../object_closure.zig");
const Projections = @import("../projections/frame.zig");
const Objects = @import("../object_closure/replay.zig");
const Assignments = @import("../assignment/application/host.zig");
const Error = zx.Error;

pub const Frame = struct {
    graph: *Graph,
    resolver: *Graph.Resolver,
    workspace: std.heap.ArenaAllocator,
    closure: ObjectClosure,
    scope: *zx.memory.ArenaScope = undefined,
    objects: if (generated) Objects else void = if (generated) .{} else {},
    assignments: if (generated) Assignments.Frame else void = undefined,
    bindings: if (generated) Bindings.Frame else void = undefined,
    non_null: if (generated) NonNull.Frame else void = undefined,
    projections: if (generated) Projections else void = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn solveRevision(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).graph.revision;
}

pub fn refreshSolverBindings(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.bindings.bind(frame.graph);
}

pub fn refreshSolverNonNull(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.non_null.bind(frame.graph);
}

pub fn refreshSolverLengths(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.projections.bindLengths(frame.graph, handle);
}

pub fn refreshSolverIndexes(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.projections.bindIndexes(frame.graph, handle);
}

pub fn refreshSolverSequences(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.projections.bindSequences(frame.graph, handle);
}

pub fn refreshSolverObjects(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.objects.bind(frame.graph, &frame.closure, frame.scope);
}

pub fn refreshSolverAssignments(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.assignments.bind(frame.graph, &frame.workspace);
}

pub fn refreshSolverValidation(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.assignments.bindValidation(frame.graph, handle);
}

pub fn resolveAssignmentEndpoint(handle: *const anyopaque, node: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const resolved = try frame.graph.resolve(@fromBackingInt(node), frame.resolver);

    frame.assignments.topology.bindTypes(frame.graph);

    return @backingInt(resolved);
}
