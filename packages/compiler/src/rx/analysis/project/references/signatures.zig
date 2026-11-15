const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Graph = @import("../source_graph/model.zig").Graph;
const Sources = @import("../source_graph/model.zig").Sources;
const Module = frontend.project.signature_project.Module;
const Index = frontend.project.source_index.Map;
const Self = @This();
pub const Forward = union(enum) { none, missing, module: usize };

graph: Graph,
modules: []const Module,
indices: []const i64,
forwards: []const Forward,
pub fn init(allocator: std.mem.Allocator, graph: Graph, modules: []const Module, paths: *const Index) std.mem.Allocator.Error!Self {
    const indices = try allocator.alloc(i64, graph.sources.zx_count);
    var forwards: []Forward = &.{};

    @memset(indices, 0);

    for (modules, 0..) |module, index| {
        const source = module.source_row;

        if (indices[source] != 0) continue;

        const number: i64 = @intCast(index + 1);

        indices[source] = if (module.signature.has_store) -number else number;

        if (module.signature.deferred_source) |path| {
            if (forwards.len == 0) {
                forwards = try allocator.alloc(Forward, modules.len);

                @memset(forwards, .none);
            }

            forwards[index] = forward(paths, path, graph.sources);
        }
    }

    return .{ .graph = graph, .modules = modules, .indices = indices, .forwards = forwards };
}

fn forward(paths: *const Index, path: []const u8, sources: Sources) Forward {
    if (comptime @import("rx_options").generated_graph and @hasField(Index, "keys")) {
        const rule = @import("generated_rx_forward_signature");

        const input: std.meta.Child(rule.Input) = .{
            .keys = paths.keys,
            .buckets = @ptrCast(&paths.buckets),
            .capacity = paths.buckets.len,
            .path = path,
            .sources = &.{ .zx_count = sources.zx_count, .rx_end = sources.rx_end },
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const row = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return if (row) |module| .{ .module = @intCast(module) } else .missing;
    }

    const target = sources.at(paths.get(path) orelse return .missing);

    return if (target == .rx) .{ .module = target.rx } else .missing;
}

pub fn forwarded(self: Self, target: usize) Forward {
    return if (self.forwards.len != 0) self.forwards[indexAt(self.indices, target) orelse return .none] else .none;
}

pub fn get(self: Self, target: usize) ?*const Module {
    return &self.modules[indexAt(self.indices, target) orelse return null];
}

/// Source signatures use one-based indices; a negative index identifies a Store setter.
pub fn indexAt(indices: []const i64, target: usize) ?usize {
    if (target >= indices.len) return null;

    const index = @abs(indices[target]);

    return if (index != 0) @intCast(index - 1) else null;
}
