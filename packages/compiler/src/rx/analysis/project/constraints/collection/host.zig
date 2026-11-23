const std = @import("std");
const zx = @import("zx");
const Collection = @import("../collection.zig");
const Defaults = @import("../../input_defaults.zig");
const rule = @import("generated_rx_collect_module_constraints");
const Input = std.meta.Child(rule.Input);
const Columns = std.meta.Child(@FieldType(Input, "default_columns"));

const Frame = struct {
    state: *Collection,
    parents: []u32 = undefined,
    marked: []bool = &.{},
    edges: std.meta.Child(@FieldType(Columns, "edges")) = undefined,
    columns: Columns = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(state: *Collection) zx.Error!void {
    var frame: Frame = .{ .state = state };
    var unused: [1]u64 = .{0};
    const count: []u64 = &unused;
    const fixed = state.states.items(.input_fixed);
    const binding_ends = state.states.items(.binding_end);
    const task_ends = state.states.items(.task_end);

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .modules = state.modules.len,
        .parents = @ptrCast(&frame.parents),
        .unused = @ptrCast(&count),
        .marked = @ptrCast(&frame.marked),
        .default_columns = &frame.columns,
        .ports = &.{
            .fixed = @ptrCast(&fixed),
            .binding_ends = @ptrCast(&binding_ends),
            .task_ends = @ptrCast(&task_ends),
        },
    };

    var scratch = std.heap.ArenaAllocator.init(state.graph.scratch);

    defer scratch.deinit();

    rule.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        error.InvalidSource => return error.InvalidSource,
        else => unreachable,
    };
}

pub fn openConstraintModule(handle: *const anyopaque, row: u64) bool {
    return Frame.borrow(handle).state.open(@intCast(row));
}

pub fn releaseConstraintScope(handle: *const anyopaque) void {
    Frame.borrow(handle).state.scope.reset(0);
}

pub fn forwardConstraintShortcut(handle: *const anyopaque) zx.Error!void {
    try Frame.borrow(handle).state.walker.forwardShortcut();
}

pub fn inferConstraintBody(handle: *const anyopaque) zx.Error!bool {
    const walker = &Frame.borrow(handle).state.walker;

    try walker.inferBody();

    return walker.returned;
}

pub fn defaultConstraintOutput(handle: *const anyopaque) zx.Error!void {
    const state = Frame.borrow(handle).state;

    try Defaults.default(state.graph, state.walker.output);
}

pub fn constraintInputUsed(handle: *const anyopaque) bool {
    return Frame.borrow(handle).state.expression.input_used;
}

pub fn constraintBindingEnd(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).state.requests.bindings.len;
}

pub fn constraintTaskEnd(handle: *const anyopaque) u64 {
    return Frame.borrow(handle).state.requests.tasks.items.len;
}

pub fn openConstraintDefaults(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const state = frame.state;
    const graph = state.graph;
    const edges = graph.pending.assignments.slice();

    frame.parents = graph.parents();

    frame.edges = .{
        .left = @ptrCast(edges.items(.value)),
        .right = @ptrCast(edges.items(.expected)),
    };

    frame.columns = .{
        .inputs = @ptrCast(state.states.items(.input)),
        .fixed = state.states.items(.input_fixed),
        .edges = &frame.edges,
    };
}

pub fn constraintVoidNode(handle: *const anyopaque) ?u32 {
    const graph = Frame.borrow(handle).state.graph;
    const void_type = @import("frontend").types.scalarId(.void);
    const node = graph.pending.known_types.get(void_type) orelse return null;

    return @backingInt(node);
}

pub fn defaultConstraintInput(handle: *const anyopaque, input: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.state.graph;

    try Defaults.default(graph, @fromBackingInt(input));

    frame.parents = graph.parents();
}
