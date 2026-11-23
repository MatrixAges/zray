const zx = @import("zx");
const Module = @import("../module.zig");
const Graph = @import("../inference/types.zig");
const Ports = @import("constraints.zig").Ports;
const Requests = @import("signatures/requests.zig");

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

pub fn borrow(ports: Ports, requests: Requests) Table {
    if (ports.len == 0) return .{};

    const bindings = requests.bindings.slice();

    return .{
        .inputs = @ptrCast(ports.items(.input)),
        .outputs = @ptrCast(ports.items(.output)),
        .binding_ends = ports.items(.binding_end),
        .task_ends = ports.items(.task_end),
        .names = bindings.items(.name),
        .binding_types = @ptrCast(bindings.items(.value)),
        .task_types = requests.tasks.items,
    };
}

pub fn resolveSeed(graph: *Graph, ports: Ports, requests: Requests) zx.Error!Table {
    const table = borrow(ports, requests);
    const inputs = @constCast(table.inputs);
    const outputs = @constCast(table.outputs);
    const binding_ends = table.binding_ends;
    const task_ends = table.task_ends;
    const binding_types = @constCast(table.binding_types);
    const task_types = @constCast(table.task_types);
    const resolveNode = @import("../inference/resolve/seed.zig").resolve;
    var binding_start: usize = 0;
    var task_start: usize = 0;

    for (inputs, outputs, binding_ends, task_ends) |*input, *output, raw_binding_end, raw_task_end| {
        const binding_end: usize = @intCast(raw_binding_end);
        const task_end: usize = @intCast(raw_task_end);

        for (binding_types[binding_start..binding_end]) |*binding| binding.* = @backingInt(try resolveNode(graph, @fromBackingInt(binding.*), 0));
        for (task_types[task_start..task_end]) |*task| task.* = binding_types[binding_start + task.*];

        input.* = @backingInt(try resolveNode(graph, @fromBackingInt(input.*), 0));
        output.* = @backingInt(try resolveNode(graph, @fromBackingInt(output.*), 0));
        binding_start = binding_end;
        task_start = task_end;
    }

    return table;
}
