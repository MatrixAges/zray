const std = @import("std");
const rx = @import("rx");
const memory = @import("zx").memory;
const Flow = @import("../flow.zig");
const Prepare = @import("../prepare.zig");
const Invocation = @import("invocation/host.zig").Invocation;
const entry = @import("generated_rx_prepare_flow");
const Input = std.meta.Child(@typeInfo(@FieldType(std.meta.Child(entry.Input), "body")).optional.child);
const Index = std.meta.Child(@FieldType(Input, "index"));
const Tree = std.meta.Child(@FieldType(Input, "tree"));
const Layout = std.meta.Child(@FieldType(Tree, "layout"));
const Capacity = @FieldType(rx.IndexedFlow, "capacity");
const Payload = std.meta.Child(@FieldType(Input, "payload"));
const Selections = std.meta.Child(@FieldType(Payload, "selections"));
const payload_lanes = 5;

fn Columns(comptime Row: type, comptime View: type, comptime field: []const u8, comptime paths: anytype) type {
    return memory.RowOutput(Row, std.meta.Child(@FieldType(View, field)), paths);
}

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

    var storage: []u32 = &.{};
    var facts: []u32 = &.{};
    var firsts: []u32 = &.{};
    var counts: []u32 = &.{};
    var rows: []u32 = &.{};
    var events: []u64 = &.{};

    const request: Request = .{
        .root = std.mem.asBytes(node),
        .layout = &comptime rx.astLayout(std.meta.Child(@FieldType(Request, "layout"))),
        .buffers = &.{
            .storage = @ptrCast(&storage),
            .facts = @ptrCast(&facts),
            .unit_firsts = @ptrCast(&firsts),
            .unit_counts = @ptrCast(&counts),
            .step_rows = @ptrCast(&rows),
            .events = @ptrCast(&events),
        },
    };

    // Keep the generated layout call separate from the caller's mutable scratch views.
    const result = @call(.never_inline, plan.executeValue, .{ scratch.allocator(), &request }) catch |err| return Prepare.loadError(err);

    const index: Index = .{
        .facts = facts,
        .events = events[0..@intCast(result.events)],
        .unit_firsts = firsts,
        .unit_counts = counts,
        .step_rows = rows,
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

    const headers = loader.plan.rows.slice();
    const kinds = std.mem.sliceAsBytes(headers.items(.kind));
    const items = headers.items(.item);
    var counters: [payload_lanes]u32 = @splat(0);
    const cursors: []u32 = &counters;
    const Rows = std.meta.Child(@FieldType(Input, "rows"));

    const rows: Rows = .{
        .kinds = @ptrCast(&kinds),
        .items = @ptrCast(&items),
        .cursors = @ptrCast(&cursors),
        .codes = &.{
            .call = @backingInt(Flow.Kind.Call),
            .result = @backingInt(Flow.Kind.Result),
            .task = @backingInt(Flow.Kind.Task),
            .parallel_task = @backingInt(Flow.Kind.ParallelTask),
            .parallel = @backingInt(Flow.Kind.Parallel),
            .selection = @backingInt(Flow.Kind.Selection),
        },
    };

    comptime {
        if (@sizeOf(Flow.Kind) != @sizeOf(u8)) @compileError("indexed flow kinds must fit in one byte");
    }

    const body = .{ .first = &.{ "body", "first" }, .count = &.{ "body", "count" } };
    var tasks: Columns(Flow.Task, Payload, "tasks", body) = undefined;
    var groups: Columns(Flow.Unit, Payload, "groups", .{}) = undefined;
    var selections: Columns(Flow.Selection, Selections, "destination", .{}) = undefined;

    var cases: Columns(Flow.Case, Selections, "body", .{
        .first = body.first,
        .count = body.count,
        .kind = &.{ "label", "kind" },
        .source = &.{ "label", "source" },
    }) = undefined;

    var results = memory.RowBuffer.empty(rx.ast.Attribute);

    tasks.init();
    groups.init();
    selections.init();
    cases.init();
    tasks.bind(loader.plan.tasks.items);
    groups.bind(loader.plan.groups.items);
    selections.bind(loader.plan.selections.items);

    results.bytes = std.mem.sliceAsBytes(loader.plan.results.items);

    var invocation: Invocation = .{ .loader = loader };
    const view = invocation.view();

    entry.executeIn(allocator, &.{
        .invocation = view,
        .body = &.{
            .index = index,
            .rows = &rows,
            .tree = tree,
            .payload = &.{
                .results = @ptrCast(&results),
                .tasks = &tasks.view,
                .groups = &groups.view,
                .selections = &.{
                    .destination = &selections.view,
                    .storage = @ptrCast(&cases.buffer),
                    .body = &cases.view,
                    .labels = &.{
                        .ordinary = @backingInt(Flow.Case.Label.Kind.Case),
                        .affirmative = @backingInt(Flow.Case.Label.Kind.Affirmative),
                        .fallback = @backingInt(Flow.Case.Label.Kind.Default),
                    },
                },
            },
        },
        .remaining = index.events.len,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.InvalidFlow => return @errorCast(err),
        else => unreachable,
    };

    std.debug.assert(std.mem.eql(u32, &counters, &.{
        capacity.calls,
        capacity.results,
        capacity.tasks,
        capacity.groups,
        capacity.selections,
    }));

    return loader.plan.finish(.{ .first = index.unit_firsts[0], .count = index.unit_counts[0] });
}
