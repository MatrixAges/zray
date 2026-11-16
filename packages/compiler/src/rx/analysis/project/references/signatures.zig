const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Graph = @import("../source_graph/model.zig").Graph;
const Sources = @import("../source_graph/model.zig").Sources;
const Module = frontend.project.signature_project.Module;
const Index = frontend.project.source_index.Map;
const Self = @This();
const generated = @import("rx_options").generated_graph;
const bulk_index = generated and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64) and @hasField(Index, "keys");
pub const Forward = union(enum) { none, missing, module: usize };
const Resolved = struct { module: *const Module, forward: Forward };
const Lookup = union(enum) { zx: ?Resolved, rx: usize, store: usize };

graph: Graph,
modules: []const Module,
indices: []const i64,
forwards: []const u64,
pub fn init(allocator: std.mem.Allocator, graph: Graph, modules: []const Module, paths: *const Index) std.mem.Allocator.Error!Self {
    const indices = try allocator.alloc(i64, graph.sources.zx_count);

    @memset(indices, 0);

    const forwards = if (comptime bulk_index)
        try @import("index.zig").publish(allocator, modules, indices, paths, graph.sources)
    else
        try publishSeed(allocator, graph.sources, modules, indices, paths);

    return .{ .graph = graph, .modules = modules, .indices = indices, .forwards = forwards };
}

fn publishSeed(allocator: std.mem.Allocator, sources: Sources, modules: []const Module, indices: []i64, paths: *const Index) std.mem.Allocator.Error![]const u64 {
    var forwards: []u64 = &.{};

    for (modules, 0..) |module, index| {
        const source = module.source_row;

        if (indices[source] != 0) continue;

        const number: i64 = @intCast(index + 1);

        indices[source] = if (module.signature.has_store) -number else number;

        if (module.signature.has_deferred_source) {
            if (forwards.len == 0) {
                forwards = try allocator.alloc(u64, modules.len);

                @memset(forwards, 0);
            }

            forwards[index] = forwardSeed(paths, module.signature.deferred_source, sources);
        }
    }

    return forwards;
}

fn forwardSeed(paths: *const Index, path: []const u8, sources: Sources) u64 {
    const target = sources.at(paths.get(path) orelse return std.math.maxInt(u64));

    return if (target == .rx) @as(u64, target.rx) + 1 else std.math.maxInt(u64);
}

pub fn lookup(self: Self, target: usize) Lookup {
    const sources = self.graph.sources;

    if (comptime generated) {
        const rule = @import("generated_rx_lookup_signature");

        const input: std.meta.Child(rule.Input) = .{
            .indices = self.indices,
            .sources = &.{ .zx_count = sources.zx_count, .rx_end = sources.rx_end },
            .owner = target,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return switch (result.kind) {
            .ZX => .{ .zx = if (result.signature) |row| self.resolve(@intCast(row)) else null },
            .RX => .{ .rx = @intCast(result.row) },
            .Store => .{ .store = @intCast(result.row) },
        };
    }

    return switch (sources.at(target)) {
        .zx => .{ .zx = if (indexAt(self.indices, target)) |row| self.resolve(row) else null },
        .rx => |row| .{ .rx = row },
        .store => |row| .{ .store = row },
    };
}

fn resolve(self: Self, row: usize) Resolved {
    const forwarding = if (self.forwards.len != 0) self.forwards[row] else 0;

    return .{
        .module = &self.modules[row],
        .forward = switch (forwarding) {
            0 => .none,
            std.math.maxInt(u64) => .missing,
            else => .{ .module = @intCast(forwarding - 1) },
        },
    };
}

/// Source signatures use one-based indices; a negative index identifies a Store setter.
pub fn indexAt(indices: []const i64, target: usize) ?usize {
    if (target >= indices.len) return null;

    const index = @abs(indices[target]);

    return if (index != 0) @intCast(index - 1) else null;
}
