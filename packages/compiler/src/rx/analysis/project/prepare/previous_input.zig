const std = @import("std");
const zx = @import("zx");
const rx = @import("rx");
const Loader = @import("../prepare.zig").Loader;
const names = @import("../../result_name.zig");
const void_type: zx.ir.TypeId = @fromBackingInt(@backingInt(zx.ir.Scalar.void));

pub fn bind(loader: *Loader, index: usize, previous: u32) Loader.Error!void {
    const calls = loader.calls.slice();

    if (calls.items(.input)[index] != null) return;

    const callees = calls.items(.callee);
    const callee = callees[index];

    if (callee == .signature and callee.signature.input_type == void_type) return;

    const rows = loader.plan.rows.slice();
    const item = rows.items(.item)[previous];
    const kind = rows.items(.kind)[previous];

    const name = switch (kind) {
        .Call => name: {
            const producer = callees[item];

            if (producer == .signature and producer.signature.output_type == void_type) return;

            break :name names.resolveCall(calls.items(.name_source)[item].*).name;
        },
        .Task => name: {
            const task = &loader.plan.tasks.items[item];

            if (task.output == null) return;

            break :name names.resolve(task.node.*).name;
        },
        else => return,
    };

    const location = calls.items(.node)[index].location;
    const prefix: []const u8 = if (kind == .Task) "$ctx.task." else "$ctx.";
    const value = try std.mem.concat(loader.allocator, u8, &.{ prefix, name });
    const attribute = try loader.allocator.create(rx.ast.Attribute);
    attribute.* = .{ .name = "in", .value = value, .kind = .expression, .location = location, .value_location = location };

    calls.items(.input)[index] = attribute;

    try loader.recordArgument(index, try loader.inputs.parse(attribute.*, loader.owner));
}
