const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Bindings = @import("../bindings/host.zig");
const generated = @import("rx_options").generated_graph;
const NonNull = @import("../non_null/host.zig");
const ObjectClosure = @import("../object_closure.zig");
const Projections = @import("../projections/frame.zig");
const Objects = @import("../object_closure/replay.zig");
const Input = @import("../../project/workflow/solve/abi.zig").Solve;
const Resolve = @import("../resolve/host.zig");
const Assignments = @import("../assignment/application/host.zig");

pub const Frame = struct {
    graph: *Graph = undefined,
    resolver: *Graph.Resolver = undefined,
    input: if (generated) Input else void = undefined,
    resolution: if (generated) Resolve.Frame else void = if (generated) .{} else {},
    workspace: std.heap.ArenaAllocator,
    closure: ObjectClosure,
    scope: *zx.memory.ArenaScope = undefined,
    objects: if (generated) Objects else void = if (generated) .{} else {},
    assignments: if (generated) Assignments.Frame else void = undefined,
    bindings: if (generated) Bindings.Frame else void = undefined,
    non_null: if (generated) NonNull.Frame else void = undefined,
    projections: if (generated) Projections else void = undefined,
    pub fn bind(self: *Frame, graph: *Graph, resolver: *Graph.Resolver, scope: *zx.memory.ArenaScope) void {
        self.graph = graph;
        self.resolver = resolver;
        self.scope = scope;
        scope.active = self.workspace.allocator();

        self.input = .{
            .frame = @ptrCast(self),
            .bindings = &self.bindings.view,
            .non_null = &self.non_null.view,
            .lengths = &self.projections.lengths,
            .indexes = &self.projections.indexes,
            .assignments = &self.assignments.view,
            .objects = &self.objects.view,
            .sequences = &self.projections.sequences,
            .validation = &self.assignments.validation,
        };
    }

    pub fn release(self: *Frame) void {
        _ = self.workspace.reset(.free_all);
        _ = self.closure.arena.reset(.free_all);
    }
    pub fn deinit(self: *Frame, scope: *zx.memory.ArenaScope) void {
        if (comptime generated) {
            self.resolution.close();
            self.objects.memory.close(scope);
        }

        self.workspace.deinit();
        self.closure.deinit();
    }

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

    frame.resolution.bind(frame.graph, frame.resolver, frame.scope);
    frame.assignments.bindValidation(frame.graph, handle, &frame.resolution.view);
}

pub fn refreshAssignmentTypes(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.assignments.topology.bindTypes(frame.graph);
}
