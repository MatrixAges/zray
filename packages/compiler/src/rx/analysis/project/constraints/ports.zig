const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../inference/types.zig");
const SourceMap = @import("../../source_map.zig");
const Prepared = @import("../prepare.zig");
const Contracts = @import("../contracts.zig");

const Row = struct {
    input: Graph.Id,
    output: Graph.Id,
    input_fixed: bool,
    binding_end: u64 = 0,
    task_end: u64 = 0,
};

const Storage = std.MultiArrayList(Row);
pub const Slice = Storage.Slice;

pub fn reserve(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Slice {
    var storage: Storage = .empty;

    try storage.setCapacity(allocator, count);

    storage.len = count;

    return storage.slice();
}

pub fn initializeSeed(graph: *Graph, modules: []const Prepared.Module, source_map: SourceMap) zx.Error!Slice {
    const rows = try reserve(graph.types.allocator, modules.len);
    var declarations = zx.Arena.init(graph.scratch);

    defer declarations.deinit();

    const declared = try Contracts.resolve(declarations.allocator(), graph, modules, source_map);

    try seed(graph, rows, modules, source_map, declared);

    return rows;
}

fn seed(graph: *Graph, destination: Slice, modules: []const Prepared.Module, source_map: SourceMap, declared: Contracts.Ports) zx.Error!void {
    var rows = destination;
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

        try publishDeclared(graph, &rows, modules, source_map, position, pair.input, pair.output);

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

fn origin(module: Prepared.Module, map: SourceMap, index: usize) zx.Span {
    const offset = map.base(index) + module.source.node.location.offset;

    return .{ .start = offset, .end = offset };
}
