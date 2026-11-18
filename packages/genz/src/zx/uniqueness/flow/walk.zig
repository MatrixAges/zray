const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Body = @import("body.zig");
const generated = @import("generated_uniqueness_flow_visit");
const Input = std.meta.Child(generated.Input);
const Environment = std.meta.Child(@FieldType(Input, "environment"));
const Layout = std.meta.Child(@FieldType(Environment, "layout"));
const Current = std.meta.Child(@FieldType(Input, "current"));
const Self = @This();

allocator: std.mem.Allocator,
flow: Flow,
slots: Slots,
scratch: ?std.heap.ArenaAllocator = null,
pub fn deinit(self: *Self) void {
    if (self.scratch) |*scratch| scratch.deinit();
}

pub fn visit(self: *Self, index: u32, function: *const ir.Function, saved: ?*const Body) std.mem.Allocator.Error!bool {
    if (self.scratch == null) self.scratch = .init(self.allocator);

    const scratch = &self.scratch.?;

    _ = scratch.reset(.retain_capacity);

    const slots = self.slots;
    const layout = Layout{ .offsets = slots.offsets, .members = @ptrCast(slots.members), .unwrapped = @ptrCast(slots.unwrapped) };
    const environment = Environment{ .layout = &layout, .type_kinds = slots.types.kinds, .type_first = slots.types.first, .counts = slots.counts };
    const source = Body.source(std.meta.Child(@FieldType(Input, "source")), function);
    const facts = if (saved) |body| body.view() else undefined;
    const current = Current{ .held = self.flow.held[index], .text_held = self.flow.text_held[index], .written = self.flow.written[index] };

    const input: Input = .{
        .function_index = index,
        .source = &source,
        .environment = &environment,
        .facts = if (saved != null) &facts else null,
        .held = self.flow.held,
        .text_held = self.flow.text_held,
        .written = self.flow.written,
        .current = &current,
    };

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (current.held.ptr != output.held.ptr) @memcpy(@constCast(current.held), output.held);
    if (current.text_held.ptr != output.text_held.ptr) @memcpy(@constCast(current.text_held), output.text_held);
    if (current.written.ptr != output.written.ptr) @memcpy(@constCast(current.written), output.written);

    return output.changed;
}
