const std = @import("std");
const rx = @import("rx");
const Flow = @import("../flow.zig");
const Prepare = @import("../prepare.zig");
const Invocation = @import("invocation/host.zig").Invocation;
const entry = @import("generated_rx_prepare_flow");
const Input = std.meta.Child(@typeInfo(@FieldType(std.meta.Child(entry.Input), "body")).optional.child);
const Index = std.meta.Child(@FieldType(Input, "index"));
const Tree = std.meta.Child(@FieldType(Input, "tree"));
const Layout = std.meta.Child(@FieldType(Tree, "layout"));
const Capacity = @FieldType(rx.IndexedFlow, "capacity");

pub fn indexed(loader: *Prepare.Loader, layout: rx.IndexedFlow) Prepare.Loader.Error!Flow.Plan {
    const index: Index = .{
        .facts = @ptrCast(layout.facts),
        .events = @ptrCast(layout.events),
        .unit_firsts = layout.unit_firsts,
        .unit_counts = layout.unit_counts,
        .step_rows = layout.step_rows,
        .parallel_tasks = layout.parallel_tasks,
    };

    const tree: Tree = .{
        .nodes = std.mem.sliceAsBytes(layout.base[0..layout.facts.len]),
        .borrowed = null,
        .layout = &comptime rx.astLayout(Layout),
    };

    return bind(loader, &index, &tree, layout.capacity);
}

pub fn borrowed(loader: *Prepare.Loader, node: *const rx.ast.Node) Prepare.Loader.Error!Flow.Plan {
    if (node.children.len == 0) return .{};

    const plan = @import("generated_rx_prepare_raw_flow");
    const Request = std.meta.Child(plan.Input);
    var scratch = std.heap.ArenaAllocator.init(loader.backing);

    defer scratch.deinit();

    const request: Request = .{
        .root = std.mem.asBytes(node),
        .layout = &comptime rx.astLayout(std.meta.Child(@FieldType(Request, "layout"))),
    };

    const result = plan.executeValue(scratch.allocator(), &request) catch |err| return Prepare.loadError(err);

    const index: Index = .{
        .facts = result.facts,
        .events = result.events,
        .unit_firsts = result.unit_firsts,
        .unit_counts = result.unit_counts,
        .step_rows = result.step_rows,
        .parallel_tasks = result.parallel_tasks,
    };

    const tree: Tree = .{
        .nodes = &.{},
        .borrowed = &.{ .nodes = result.tree.nodes, .children = result.tree.children },
        .layout = &comptime rx.astLayout(Layout),
    };

    var capacity: Capacity = undefined;

    inline for (@typeInfo(Capacity).@"struct".field_names) |name| {
        @field(capacity, name) = std.math.cast(u32, @field(result.capacity, name)) orelse return error.OutOfMemory;
    }

    return bind(loader, &index, &tree, capacity);
}

fn bind(loader: *Prepare.Loader, index: *const Index, tree: *const Tree, capacity: Capacity) Prepare.Loader.Error!Flow.Plan {
    const allocator = loader.allocator;
    loader.plan = try Flow.Builder.init(allocator, capacity);

    try loader.calls.setCapacity(allocator, capacity.calls);

    var invocation: Invocation = .{ .loader = loader };
    const view = invocation.view();
    const Rows = std.meta.Child(@FieldType(Input, "rows"));

    const rows: Rows = .{
        .cursors = &invocation.cursors,
        .codes = &.{
            .call = @backingInt(Flow.Kind.Call),
            .result = @backingInt(Flow.Kind.Result),
            .task = @backingInt(Flow.Kind.Task),
            .parallel_task = @backingInt(Flow.Kind.ParallelTask),
            .parallel = @backingInt(Flow.Kind.Parallel),
            .selection = @backingInt(Flow.Kind.Selection),
        },
    };

    var scratch = std.heap.ArenaAllocator.init(loader.backing);

    defer scratch.deinit();

    entry.executeIn(scratch.allocator(), &.{
        .invocation = view,
        .body = &.{
            .index = index,
            .rows = &rows,
            .tree = tree,
            .labels = &.{
                .ordinary = @backingInt(Flow.Case.Label.Kind.Case),
                .affirmative = @backingInt(Flow.Case.Label.Kind.Affirmative),
                .fallback = @backingInt(Flow.Case.Label.Kind.Default),
            },
        },
        .remaining = index.events.len,
    }) catch |err| return Prepare.loadError(err);

    std.debug.assert(std.mem.eql(u32, &invocation.cursors, &.{
        capacity.calls,
        capacity.results,
        capacity.tasks,
        capacity.groups,
        capacity.selections,
    }));

    return loader.plan.finish(.{ .first = index.unit_firsts[0], .count = index.unit_counts[0] });
}
