const std = @import("std");
const zx = @import("zx");
const Collection = @import("../collection.zig");
const Defaults = @import("../../input_defaults.zig");
const Input = @import("../../workflow/solve/abi.zig").Collection;
const Columns = std.meta.Child(@FieldType(Input, "default_columns"));

pub const Frame = struct {
    state: *Collection = undefined,
    input: Input = undefined,
    edges: std.meta.Child(@FieldType(Columns, "edges")) = undefined,
    known: std.meta.Child(@FieldType(Input, "default_known")) = undefined,
    columns: Columns = undefined,
    pub fn bind(self: *Frame, state: *Collection) void {
        self.state = state;

        self.input = .{
            .modules = state.modules.len,
            .default_columns = &self.columns,
            .default_known = &self.known,
        };
    }
    pub fn commit(frame: *Frame, effect: anytype, reply: anytype) zx.Error!void {
        const state = frame.state;

        switch (effect.collection_step) {
            .Open => {
                const index: usize = @intCast(effect.row.?);
                reply.shortcut = state.open(index);
                reply.input_fixed = state.states.items(.input_fixed)[index];
            },
            .Release => state.scope.reset(0),
            .Forward => {
                try state.walker.forwardShortcut();

                frame.summarize(reply);
            },
            .Infer => {
                try state.walker.inferBody();

                frame.summarize(reply);
            },
            .DefaultOutput => try Defaults.default(state.graph, state.walker.output),
            .PublishPort => {
                const index: usize = @intCast(effect.row.?);

                state.states.items(.input_fixed)[index] = effect.fixed.?;
                state.states.items(.binding_end)[index] = effect.binding_end.?;
                state.states.items(.task_end)[index] = effect.task_end.?;
            },
            .OpenDefaults => reply.parents = frame.openDefaults(),
            .DefaultInput => {
                try Defaults.default(state.graph, @fromBackingInt(effect.input.?));

                reply.parents = state.graph.parents();
            },
        }
    }
    fn summarize(frame: *Frame, reply: anytype) void {
        const state = frame.state;
        reply.returned = state.walker.returned;
        reply.used = state.expression.input_used;
        reply.bindings = state.requests.bindings.len;
        reply.tasks = state.requests.tasks.items.len;
    }

    fn openDefaults(frame: *Frame) []const u32 {
        const state = frame.state;
        const graph = state.graph;
        const edges = graph.pending.assignments.slice();

        frame.edges = .{
            .left = @ptrCast(edges.items(.value)),
            .right = @ptrCast(edges.items(.expected)),
        };

        frame.known = graph.pending.known_types.borrow(@TypeOf(frame.known));

        frame.columns = .{
            .inputs = @ptrCast(state.states.items(.input)),
            .fixed = state.states.items(.input_fixed),
            .edges = &frame.edges,
        };

        return graph.parents();
    }
};
