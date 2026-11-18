const std = @import("std");
const zx = @import("zx");
const rx = @import("rx");
const Loader = @import("../prepare.zig").Loader;
const Callee = @import("../prepare.zig").Callee;
const Flow = @import("../flow.zig");
const names = @import("../../result_name.zig");
const void_type: zx.ir.TypeId = @fromBackingInt(@backingInt(zx.ir.Scalar.void));
const Output = struct { name: []const u8, task: bool = false };

pub fn bind(loader: *Loader, plan: Flow.Plan, unit: Flow.Unit) Loader.Error!void {
    var previous: ?Output = null;
    const items = plan.items[unit.first..][0..unit.count];
    const kinds = plan.kinds[unit.first..][0..unit.count];

    for (kinds, items) |kind, row| {
        previous = switch (kind) {
            .Call => try bindCall(loader, row, previous),
            .Task => output: {
                const task = &plan.tasks[row];

                try bind(loader, plan, task.body);

                break :output if (task.output != null) .{ .name = names.resolve(task.node.*).name, .task = true } else null;
            },
            .Selection => output: {
                for (plan.selections[row].cases) |*branch| try bind(loader, plan, branch.body);

                break :output null;
            },
            .Parallel => output: {
                const group = plan.groups[row];
                const first = group.first;
                const end = first + group.count;

                for (plan.kinds[first..end], plan.items[first..end]) |branch, item| {
                    if (branch == .ParallelTask) try bind(loader, plan, plan.tasks[item].body);
                }

                break :output null;
            },
            .Result, .ParallelTask => null,
        };
    }
}

fn bindCall(loader: *Loader, index: u32, previous: ?Output) Loader.Error!?Output {
    const calls = loader.calls.slice();
    const node = &calls.items(.node)[index];
    const slot = &calls.items(.input)[index];
    const callee = calls.items(.callee)[index];

    if (slot.* == null and acceptsInput(callee)) {
        if (previous) |output| {
            const attribute = try loader.allocator.create(rx.ast.Attribute);
            const value = try std.mem.concat(loader.allocator, u8, &.{ if (output.task) "$ctx.task." else "$ctx.", output.name });
            attribute.* = .{ .name = "in", .value = value, .kind = .expression, .location = node.location, .value_location = node.location };
            slot.* = attribute;

            try loader.recordArgument(index, try loader.inputs.parse(attribute.*, loader.owner));
        }
    }

    if (callee == .signature and callee.signature.output_type == void_type) return null;

    return .{ .name = names.resolveCall(calls.items(.name_source)[index].*).name };
}

fn acceptsInput(callee: Callee) bool {
    return callee == .module or callee.signature.input_type != void_type;
}
