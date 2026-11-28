const std = @import("std");
const ir = @import("../hardware/ir.zig");
const hardware = @import("../hardware/root.zig");

pub fn emit(allocator: std.mem.Allocator, module: ir.Module, clocked: bool) ![]u8 {
    return renderModule(allocator, module, clocked);
}

pub fn emitCircuit(allocator: std.mem.Allocator, module: hardware.Circuit, clocked: bool) ![]u8 {
    return renderModule(allocator, module, clocked);
}

fn renderModule(allocator: std.mem.Allocator, module: anytype, clocked: bool) ![]u8 {
    const View = @import("../hardware/graph/view.zig");
    var temporary = std.heap.ArenaAllocator.init(allocator);

    defer temporary.deinit();

    var view: View = undefined;

    try view.init(temporary.allocator(), module);

    const render = @import("generated_render_verilog");
    const Input = std.meta.Child(render.Input);
    const circuit = view.scan();

    const layout: std.meta.Child(@FieldType(Input, "layout")) = .{
        .inputs = &view.inputs,
        .outputs = &view.outputs,
        .safe = view.graph.safe,
        .clocked = clocked,
    };

    const input: Input = .{ .layout = &layout, .circuit = &circuit };

    const rendered = render.executeIn(temporary.allocator(), &input) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };

    const text = rendered orelse return error.InvalidHardwareIr;

    return allocator.dupe(u8, text);
}
