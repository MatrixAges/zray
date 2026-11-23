const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../inference/types.zig");
const Expression = @import("../../inference/expression.zig");
const SourceMap = @import("../../source_map.zig");
const Prepared = @import("../prepare.zig");
const Inputs = @import("../call_inputs.zig");
const Requests = @import("../signatures/requests.zig");
const Defaults = @import("../input_defaults.zig");
const Constraints = @import("../constraints.zig");
const Self = @This();

graph: *Graph,
modules: []const Prepared.Module,
source_map: SourceMap,
states: Constraints.Ports,
arguments: *const Inputs,
requests: *Requests,
scope: zx.Arena,
expression: Expression = undefined,

walker: Constraints.Walker = undefined,
pub fn open(self: *Self, row: usize) bool {
    self.scope.reset(std.heap.page_size_min);

    const module = &self.modules[row];
    const location = module.source.node.location;

    self.expression = .{
        .graph = self.graph,
        .scope = self.scope.allocator(),
        .aliases = module.value_imports,
        .input = self.states.items(.input)[row],
        .attribute = .{ .name = "", .value = "", .location = location, .value_location = location },
        .span_offset = self.source_map.base(row),
    };

    self.walker = .{
        .expression = &self.expression,
        .module = module,
        .states = self.states,
        .output = self.states.items(.output)[row],
        .arguments = self.arguments.module(row),
        .requests = self.requests,
        .binding_first = self.requests.bindings.len,
        .task_first = self.requests.tasks.items.len,
    };

    return module.deferred_shortcut;
}

pub fn seed(self: *Self) zx.Error!void {
    const fixed = self.states.items(.input_fixed);
    const binding_ends = self.states.items(.binding_end);
    const task_ends = self.states.items(.task_end);
    var unused: usize = 0;

    for (0..self.modules.len) |row| {
        if (self.open(row)) {
            try self.walker.forwardShortcut();

            fixed[row] = true;
        } else {
            try self.walker.inferBody();
            if (!self.walker.returned) try Defaults.default(self.graph, self.walker.output);

            fixed[row] = fixed[row] or self.expression.input_used;
        }

        unused += @intFromBool(!fixed[row]);
        binding_ends[row] = self.requests.bindings.len;
        task_ends[row] = self.requests.tasks.items.len;
    }

    self.scope.reset(0);

    if (unused != 0) try Defaults.seed(self.graph, self.states.items(.input), fixed);
}
