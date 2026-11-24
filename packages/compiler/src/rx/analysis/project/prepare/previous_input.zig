const std = @import("std");
const zx = @import("zx");
const rx = @import("rx");
const Loader = @import("../prepare.zig").Loader;
const names = @import("../../result_name.zig");
pub const Kind = @import("../flow.zig").Kind;
pub const void_type: zx.ir.TypeId = @fromBackingInt(@backingInt(zx.ir.Scalar.void));

pub fn kind(loader: *const Loader, row: u32) Kind {
    return loader.plan.rows.items(.kind)[row];
}

pub fn name(loader: *const Loader, row: u32, task_output: bool) ?[]const u8 {
    const item = loader.plan.rows.items(.item)[row];

    if (task_output) {
        const task = &loader.plan.tasks.items[item];

        return if (task.output != null) names.resolve(task.node.*).name else null;
    }

    const producer = loader.calls.items(.callee)[item];

    if (producer == .signature and producer.signature.output_type == void_type) return null;

    return names.resolveCall(loader.calls.items(.name_source)[item].*).name;
}

pub fn seed(loader: *Loader, index: usize, row: u32) std.mem.Allocator.Error!void {
    const task = switch (kind(loader, row)) {
        .Call => false,
        .Task => true,
        else => return,
    };

    const result = name(loader, row, task) orelse return;
    const value = try std.mem.concat(loader.allocator, u8, &.{ if (task) "$ctx.task." else "$ctx.", result });

    try publish(loader, index, value);
}

pub fn publish(loader: *Loader, index: usize, value: []const u8) std.mem.Allocator.Error!void {
    const location = loader.calls.items(.node)[index].location;
    const attribute = try loader.allocator.create(rx.ast.Attribute);
    attribute.* = .{ .name = "in", .value = value, .kind = .expression, .location = location, .value_location = location };

    loader.calls.items(.input)[index] = attribute;

    try loader.recordArgument(index, try loader.inputs.parse(attribute.*, loader.owner));
}
