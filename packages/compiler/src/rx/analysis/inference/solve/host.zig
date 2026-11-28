const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Bindings = @import("../bindings/host.zig");
const generated = @import("rx_options").generated_graph;
const NonNull = @import("../non_null/host.zig");
const ObjectClosure = @import("../object_closure.zig");
const Projections = @import("../projections/frame.zig");
const Known = @import("../known.zig");
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

    pub fn replay(self: *Frame, effect: anytype, reply: anytype) zx.Error!void {
        const graph = self.graph;

        switch (effect.step) {
            .ReadRevision => reply.revision = graph.revision,
            .RefreshLengths => self.projections.bindLengths(graph),
            .RefreshIndexes => self.projections.bindIndexes(graph),
            .MarkIndexResolved => graph.pending.indexes.items(.resolved)[@intCast(effect.row.?)] = true,
            .RefreshSequences => self.projections.bindSequences(graph),
            .RefreshObjects => self.objects.bind(graph, &self.closure, self.scope),
            .RefreshAssignments => self.assignments.bind(graph),
            .RefreshValidation => {
                self.resolution.bind(graph, self.resolver, self.scope);
                self.assignments.bindValidation(graph, &self.resolution.view);
            },
            .RefreshAssignmentTypes => self.assignments.topology.bindTypes(graph),
            .RegisterAssignmentPayload => {
                const span = graph.nodes.items(.span)[effect.left.?];
                const result = try Known.registerPayload(graph, effect.right.?, effect.budget.?, span);

                self.assignments.refresh();

                reply.id = @backingInt(result.node);
                reply.remaining = result.remaining;
            },
            .ReserveAssignmentOptional => {
                const span = graph.nodes.items(.span)[effect.left.?];
                const count = std.math.cast(usize, effect.budget.?) orelse return error.OutOfMemory;

                reply.id = @backingInt(try graph.addContainers(@fromBackingInt(effect.right.?), .optional, count, span));
            },
            .MergeAssignmentClass => {
                const index: u32 = @intCast(effect.row.?);

                try graph.unify(@fromBackingInt(index), @fromBackingInt(effect.right.?), graph.nodes.items(.span)[index]);

                self.assignments.refresh();
            },
            .RejectAssignmentDepth => return graph.reporter.fail(.unsupported, graph.nodes.items(.span)[effect.left.?], "type inference nesting exceeds 256 levels"),
            .UnifyBinding => try self.bindings.unify(@intCast(effect.row.?), effect.right.?),
            .RefreshBindings => self.bindings.bind(graph),
            .RejectBinding => return self.bindings.reject(effect.diagnostic.?),
            .MergeNonNull => try self.non_null.merge(@intCast(effect.row.?), effect.left.?, effect.right.?),
            .RefreshNonNull => self.non_null.bind(graph),
            .ReserveNonNull => reply.id = try self.non_null.reserve(@intCast(effect.row.?), effect.right.?),
            .RegisterNonNull => reply.id = try self.non_null.register(@intCast(effect.row.?), effect.right.?),
        }
    }
};
