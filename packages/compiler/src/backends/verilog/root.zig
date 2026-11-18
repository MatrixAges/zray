const std = @import("std");
const ir = @import("../hardware/ir.zig");

pub fn emit(allocator: std.mem.Allocator, module: ir.Module, clocked: bool) ![]u8 {
    if (comptime !@import("parser_options").generated_parser) {
        if (!@import("../hardware/validate.zig").validate(module)) return error.InvalidHardwareIr;

        return @import("seed/root.zig").emit(allocator, module, clocked);
    }

    const View = @import("../hardware/graph/view.zig");
    var view: View = undefined;

    view.init(module);

    if (!view.validate(module.nodes)) return error.InvalidHardwareIr;

    var temporary = std.heap.ArenaAllocator.init(allocator);

    defer temporary.deinit();

    const capacity = @import("generated_verilog_capacity");

    const lower_bound = try capacity.executeValue(temporary.allocator(), &.{
        .nodes = module.nodes.len,
        .inputs = module.inputs.len,
        .outputs = module.outputs.len,
        .clocked = clocked,
    });

    const initial_size = std.math.cast(usize, lower_bound) orelse return error.OutOfMemory;
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, initial_size);

    errdefer output.deinit();

    const header = @import("generated_verilog_header");
    const write = @import("generated_verilog_node");
    const finish = @import("generated_verilog_finish");

    const frame: std.meta.Child(header.Input) = .{
        .writer = @ptrCast(&output.writer),
        .inputs = &view.inputs,
        .outputs = &view.outputs,
        .safe = view.graph.safe,
        .clocked = clocked,
    };

    header.executeValue(temporary.allocator(), &frame) catch |err| return writerError(err);

    for (module.nodes, 0..) |*node, index| {
        const row = View.project(node);

        write.executeValue(temporary.allocator(), &.{ .writer = frame.writer, .index = index, .node = &row, .widths = view.sorts.widths, .input_names = view.inputs.names }) catch |err| return writerError(err);
    }

    finish.executeValue(temporary.allocator(), &frame) catch |err| return writerError(err);

    return output.toOwnedSlice();
}

fn writerError(err: error{ IndexOutOfBounds, OutOfMemory }) error{WriteFailed} {
    return switch (err) {
        error.OutOfMemory => error.WriteFailed,
        error.IndexOutOfBounds => unreachable,
    };
}
