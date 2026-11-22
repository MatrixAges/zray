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

    var temporary = std.heap.ArenaAllocator.init(allocator);

    defer temporary.deinit();

    var output = std.Io.Writer.Allocating.init(allocator);

    errdefer output.deinit();

    const render = @import("generated_render_verilog");
    const Input = std.meta.Child(render.Input);
    const circuit = view.scan();
    const target = &output;

    const layout: std.meta.Child(@FieldType(Input, "layout")) = .{
        .writer = @ptrCast(&output.writer),
        .inputs = &view.inputs,
        .outputs = &view.outputs,
        .safe = view.graph.safe,
        .clocked = clocked,
    };

    const input: Input = .{ .target = @ptrCast(&target), .layout = &layout, .circuit = &circuit };

    const valid = render.executeIn(temporary.allocator(), &input) catch |err| return switch (err) {
        error.OutputCapacity => error.OutOfMemory,
        error.OutOfMemory => error.WriteFailed,
        error.IndexOutOfBounds, error.IntegerOverflow => unreachable,
    };

    if (!valid) return error.InvalidHardwareIr;

    return output.toOwnedSlice();
}

pub fn reserveVerilogOutput(handle: *const anyopaque, capacity: u64) error{OutputCapacity}!void {
    const reference: *const *std.Io.Writer.Allocating = @ptrCast(@alignCast(handle));
    const output = reference.*;
    const size = std.math.cast(usize, capacity) orelse return error.OutputCapacity;

    output.* = std.Io.Writer.Allocating.initCapacity(output.allocator, size) catch return error.OutputCapacity;
}
