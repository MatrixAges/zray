const std = @import("std");
const zx = @import("zx");
const Collection = @import("../collection.zig");
const Defaults = @import("../../input_defaults.zig");
const Input = @import("../../workflow/solve/abi.zig").Collection;
const Columns = std.meta.Child(@FieldType(Input, "default_columns"));
const layouts = @import("rx_execution_abi").layouts.@"zig:rx_project_host";
const Module = layouts.ConstraintModule;
const Body = layouts.ConstraintBody;

pub const Frame = struct {
    state: *Collection = undefined,
    input: Input = undefined,
    parents: []u32 = undefined,
    edges: std.meta.Child(@FieldType(Columns, "edges")) = undefined,
    known: std.meta.Child(@FieldType(Input, "default_known")) = undefined,
    columns: Columns = undefined,
    module: Module = undefined,
    body: Body = undefined,
    pub fn bind(self: *Frame, state: *Collection) void {
        self.state = state;

        self.input = .{
            .frame = @ptrCast(self),
            .modules = state.modules.len,
            .parents = @ptrCast(&self.parents),
            .default_columns = &self.columns,
            .default_known = &self.known,
        };
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
    fn summarize(self: *Frame) *const Body {
        const state = self.state;

        self.body = .{
            .returned = state.walker.returned,
            .used = state.expression.input_used,
            .binding_end = state.requests.bindings.len,
            .task_end = state.requests.tasks.items.len,
        };

        return &self.body;
    }
};

pub fn openConstraintModule(handle: *anyopaque, row: u64) *const Module {
    const frame = Frame.borrow(handle);
    const index: usize = @intCast(row);
    const shortcut = frame.state.open(index);

    frame.module = .{
        .shortcut = shortcut,
        .fixed = frame.state.states.items(.input_fixed)[index],
    };

    return &frame.module;
}

pub fn releaseConstraintScope(handle: *anyopaque) void {
    Frame.borrow(handle).state.scope.reset(0);
}

pub fn forwardConstraintShortcut(handle: *anyopaque) zx.Error!*const Body {
    const frame = Frame.borrow(handle);

    try frame.state.walker.forwardShortcut();

    return frame.summarize();
}

pub fn inferConstraintBody(handle: *anyopaque) zx.Error!*const Body {
    const frame = Frame.borrow(handle);
    const walker = &frame.state.walker;

    try walker.inferBody();

    return frame.summarize();
}

pub fn defaultConstraintOutput(handle: *anyopaque) zx.Error!void {
    const state = Frame.borrow(handle).state;

    try Defaults.default(state.graph, state.walker.output);
}

pub fn commitConstraintPort(handle: *anyopaque, row: u64, fixed: bool, binding_end: u64, task_end: u64) void {
    const states = Frame.borrow(handle).state.states;
    const index: usize = @intCast(row);

    states.items(.input_fixed)[index] = fixed;
    states.items(.binding_end)[index] = binding_end;
    states.items(.task_end)[index] = task_end;
}

pub fn openConstraintDefaults(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);
    const state = frame.state;
    const graph = state.graph;
    const edges = graph.pending.assignments.slice();

    frame.parents = graph.parents();

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
}

pub fn defaultConstraintInput(handle: *anyopaque, input: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.state.graph;

    try Defaults.default(graph, @fromBackingInt(input));

    frame.parents = graph.parents();
}
