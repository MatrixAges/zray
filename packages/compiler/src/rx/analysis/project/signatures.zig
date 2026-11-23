const zx = @import("zx");
const Module = @import("../module.zig");
const Graph = @import("../inference/types.zig");
const Ports = @import("constraints.zig").Ports;
const Requests = @import("signatures/requests.zig");
const generated = @import("rx_options").generated_graph;

pub const Signature = struct {
    input_type: zx.ir.TypeId,
    output_type: zx.ir.TypeId,
    bindings: Module.Bindings,
    tasks: []const zx.ir.TypeId,
};

pub const Table = struct {
    inputs: []const u32 = &.{},
    outputs: []const u32 = &.{},
    binding_ends: []const u64 = &.{},
    task_ends: []const u64 = &.{},
    names: []const []const u8 = &.{},
    binding_types: []const u32 = &.{},
    task_types: []const u32 = &.{},
    pub fn at(self: *const Table, row: usize) Signature {
        const first: usize = if (row == 0) 0 else @intCast(self.binding_ends[row - 1]);
        const end: usize = @intCast(self.binding_ends[row]);
        const task_first: usize = if (row == 0) 0 else @intCast(self.task_ends[row - 1]);
        const task_end: usize = @intCast(self.task_ends[row]);

        return .{
            .input_type = @fromBackingInt(self.inputs[row]),
            .output_type = @fromBackingInt(self.outputs[row]),
            .bindings = .{ .names = self.names[first..end], .types = @ptrCast(self.binding_types[first..end]) },
            .tasks = @ptrCast(self.task_types[task_first..task_end]),
        };
    }
};

pub fn resolve(graph: *Graph, resolver: *Graph.Resolver, ports: Ports, requests: Requests) zx.Error!Table {
    if (ports.len == 0) return .{};

    const task_types = requests.tasks.items;
    const bindings = requests.bindings.slice();
    const names = bindings.items(.name);
    const binding_types: []u32 = @ptrCast(bindings.items(.value));
    const inputs: []u32 = @ptrCast(ports.items(.input));
    const outputs: []u32 = @ptrCast(ports.items(.output));
    const binding_ends = ports.items(.binding_end);
    const task_ends = ports.items(.task_end);

    if (comptime generated) {
        try @import("signatures/host.zig").run(graph, resolver, .{
            .inputs = inputs,
            .outputs = outputs,
            .binding_ends = binding_ends,
            .task_ends = task_ends,
            .bindings = binding_types,
            .tasks = task_types,
        });
    } else {
        const resolveSeed = @import("../inference/resolve/seed.zig").resolve;
        var binding_start: usize = 0;
        var task_start: usize = 0;

        for (inputs, outputs, binding_ends, task_ends) |*input, *output, raw_binding_end, raw_task_end| {
            const binding_end: usize = @intCast(raw_binding_end);
            const task_end: usize = @intCast(raw_task_end);

            for (binding_types[binding_start..binding_end]) |*binding| binding.* = @backingInt(try resolveSeed(graph, @fromBackingInt(binding.*), 0));
            for (task_types[task_start..task_end]) |*task| task.* = binding_types[binding_start + task.*];

            input.* = @backingInt(try resolveSeed(graph, @fromBackingInt(input.*), 0));
            output.* = @backingInt(try resolveSeed(graph, @fromBackingInt(output.*), 0));
            binding_start = binding_end;
            task_start = task_end;
        }
    }

    return .{
        .inputs = inputs,
        .outputs = outputs,
        .binding_ends = binding_ends,
        .task_ends = task_ends,
        .names = names,
        .binding_types = binding_types,
        .task_types = task_types,
    };
}
