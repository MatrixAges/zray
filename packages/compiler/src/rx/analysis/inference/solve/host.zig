const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Assignment = @import("../assignment.zig");
const Bindings = @import("../bindings/host.zig");
const generated = @import("rx_options").generated_graph;
const Construction = @import("../construction.zig");
const Index = @import("../index.zig");
const NonNull = @import("../non_null.zig");
const ObjectClosure = @import("../object_closure.zig");
const Projections = @import("../projections.zig");
const Selection = @import("../selection.zig");
const Sequences = @import("../sequences.zig");
const Defaults = @import("../sequences/defaults/apply.zig");
const Error = zx.Error;

pub const Frame = struct {
    graph: *Graph,
    resolver: *Graph.Resolver,
    workspace: std.heap.ArenaAllocator,
    closure: ObjectClosure,
    classes: Assignment.Base = undefined,
    bindings: if (generated) Bindings.Frame else void = undefined,
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

pub fn solveNonNull(handle: *const anyopaque, final: bool) Error!bool {
    const graph = Frame.borrow(handle).graph;
    const revision = graph.revision;

    try NonNull.propagate(graph, final);

    return final and graph.revision != revision;
}

pub fn solveSequences(handle: *const anyopaque) Error!void {
    try Sequences.replay(Frame.borrow(handle).graph);
}

pub fn solveConstructions(handle: *const anyopaque, final: bool) Error!bool {
    const frame = Frame.borrow(handle);
    const revision = frame.graph.revision;

    try Construction.replay(frame.graph, &frame.closure, final);

    return final and frame.graph.revision != revision;
}

pub fn solveSelections(handle: *const anyopaque, final: bool) Error!bool {
    const frame = Frame.borrow(handle);
    const revision = frame.graph.revision;

    try Selection.replay(frame.graph, &frame.closure, final);

    return final and frame.graph.revision != revision;
}

pub fn solveLengths(handle: *const anyopaque) Error!void {
    try Projections.applyLengths(Frame.borrow(handle).graph);
}

pub fn solveIndexes(handle: *const anyopaque, revision: u64) Error!bool {
    const graph = Frame.borrow(handle).graph;

    try Index.replay(graph);

    return graph.revision != revision;
}

pub fn solveAssignmentClasses(handle: *const anyopaque) Error!bool {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const revision = graph.revision;
    _ = frame.workspace.reset(.retain_capacity);
    frame.classes = try Assignment.Base.init(graph, frame.workspace.allocator());

    try frame.classes.propagate(graph);

    return graph.revision != revision;
}

pub fn solveSequenceDefaults(handle: *const anyopaque) Error!bool {
    const frame = Frame.borrow(handle);

    return Defaults.apply(frame.graph, frame.classes, frame.workspace.allocator());
}

pub fn solveMaterializeAssignments(handle: *const anyopaque) Error!bool {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const revision = graph.revision;

    try Assignment.materialize(graph, frame.classes, frame.workspace.allocator());

    return graph.revision != revision;
}

pub fn solveIndexDefaults(handle: *const anyopaque) Error!bool {
    return Index.defaultLists(Frame.borrow(handle).graph);
}

pub fn solveValidateLengths(handle: *const anyopaque) Error!void {
    try Projections.validateLengths(Frame.borrow(handle).graph);
}

pub fn solveValidateAssignments(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    try Assignment.validate(frame.graph, frame.resolver);
}
