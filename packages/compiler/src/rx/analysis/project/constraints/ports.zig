const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../inference/types.zig");
const Nodes = @import("../../inference/nodes.zig");
const SourceMap = @import("../../source_map.zig");
const Prepared = @import("../prepare.zig");
const Contracts = @import("../contracts.zig");
const generated = @import("rx_options").generated_graph;

const Row = struct {
    input: Graph.Id,
    output: Graph.Id,
    input_fixed: bool,
    binding_end: usize = 0,
    task_end: usize = 0,
};

const Storage = std.MultiArrayList(Row);
pub const Slice = Storage.Slice;

pub fn initialize(graph: *Graph, modules: []const Prepared.Module, source_map: SourceMap) zx.Error!Slice {
    var storage: Storage = .empty;

    try storage.resize(graph.allocator, modules.len);

    var declarations = zx.Arena.init(graph.scratch);

    defer declarations.deinit();

    const declared = try Contracts.resolve(declarations.allocator(), graph, modules, source_map);
    var rows = storage.slice();

    if (comptime generated) {
        try publishRanges(graph, &rows, modules, source_map, declared);
    } else {
        try seed(graph, &rows, modules, source_map, declared);
    }

    return rows;
}

fn publishRanges(graph: *Graph, rows: *Slice, modules: []const Prepared.Module, source_map: SourceMap, declared: Contracts.Ports) zx.Error!void {
    if (modules.len == 0) return;
    if (declared.owners.len == 0) return inferred(graph, rows.*, modules, source_map, 0, modules.len);

    const rule = @import("generated_rx_port_ranges");
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var cursor: u64 = 0;
    var position: usize = 0;

    while (position < modules.len) {
        const input: std.meta.Child(rule.Input) = .{
            .owners = declared.owners,
            .types = @ptrCast(declared.types),
            .start = cursor,
            .modules = modules.len,
        };

        const range = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        const end: usize = @intCast(range.inferred_until);

        if (position < end) try inferred(graph, rows.*, modules, source_map, position, end);
        if (!range.declared) return;
        try publishDeclared(graph, rows, modules, source_map, end, @fromBackingInt(range.input), @fromBackingInt(range.output));

        cursor = range.next;
        position = end + 1;
    }
}

fn seed(graph: *Graph, rows: *Slice, modules: []const Prepared.Module, source_map: SourceMap, declared: Contracts.Ports) zx.Error!void {
    var next = declared.seedAt(0);
    var position: usize = 0;

    while (position < modules.len) {
        const end = if (next) |pair| pair.owner else modules.len;

        if (position < end) {
            for (position..end) |index| {
                const span = origin(modules[index], source_map, index);

                rows.set(index, .{
                    .input = try graph.add(.unknown, span),
                    .output = try graph.add(.unknown, span),
                    .input_fixed = false,
                });
            }

            position = end;

            continue;
        }

        const pair = next.?;

        try publishDeclared(graph, rows, modules, source_map, position, pair.input, pair.output);

        next = declared.seedAt(pair.next);
        position += 1;
    }
}

fn publishDeclared(graph: *Graph, rows: *Slice, modules: []const Prepared.Module, source_map: SourceMap, index: usize, input: zx.ir.TypeId, output: zx.ir.TypeId) zx.Error!void {
    const span = origin(modules[index], source_map, index);

    rows.set(index, .{
        .input = try graph.known(input, span),
        .output = try graph.known(output, span),
        .input_fixed = true,
    });
}

fn inferred(graph: *Graph, rows: Slice, modules: []const Prepared.Module, source_map: SourceMap, first: usize, end: usize) zx.Error!void {
    const count = end - first;
    const length = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    const reservation = try Nodes.reserve(graph, length);
    const rule = @import("generated_rx_inferred_ports");
    const Input = std.meta.Child(rule.Input);
    const Topology = std.meta.Child(@FieldType(Input, "nodes"));
    const view = Nodes.writable(reservation.rows);
    const parents = reservation.rows.items(.parent);
    const inputs: []u32 = @ptrCast(rows.items(.input)[first..end]);
    const outputs: []u32 = @ptrCast(rows.items(.output)[first..end]);
    const fixed = std.mem.sliceAsBytes(rows.items(.input_fixed)[first..end]);

    const input: Input = .{
        .nodes = &.{
            .parents = @ptrCast(&parents),
            .columns = &view.borrow(std.meta.Child(@FieldType(Topology, "columns"))),
            .shape = &.{ .kind = @backingInt(Nodes.Kind.Unknown), .argument = 0, .members = &.{} },
            .first = reservation.first,
            .end = reservation.rows.len,
        },
        .ports = &.{
            .inputs = @ptrCast(&inputs),
            .outputs = @ptrCast(&outputs),
            .fixed = @ptrCast(&fixed),
            .first_node = reservation.first,
            .count = count,
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    const spans = reservation.rows.items(.span)[reservation.first..];

    for (first..end, 0..) |index, offset| {
        const span = origin(modules[index], source_map, index);

        spans[offset * 2] = span;
        spans[offset * 2 + 1] = span;
    }

    @memset(rows.items(.binding_end)[first..end], 0);
    @memset(rows.items(.task_end)[first..end], 0);
    reservation.finish(graph);
}

fn origin(module: Prepared.Module, map: SourceMap, index: usize) zx.Span {
    const offset = map.base(index) + module.source.node.location.offset;

    return .{ .start = offset, .end = offset };
}
