const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Flow = @import("../flow.zig");
const Memo = @import("../memo.zig");
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

pub fn adopt(self: *const Self, index: u32, cached: Memo.Flowed) bool {
    const entry = @import("generated_uniqueness_flow_adopt");
    const Adoption = std.meta.Child(entry.Input);
    const current = self.row(index);

    const input: Adoption = .{
        .current = zx.columns.pointer(@FieldType(Adoption, "current"), &current),
        .target = &target(std.meta.Child(@FieldType(Adoption, "target")), &current),
        .cached = &.{ .held = cached.held, .text_held = cached.text_held, .written = cached.written },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}

fn row(self: *const Self, index: u32) Current {
    const flow = self.flow;

    return .{ .held = flow.held[index], .text_held = flow.text_held[index], .written = flow.written[index] };
}

fn target(comptime Target: type, current: *const Current) Target {
    return .{
        .held = @ptrCast(&current.held),
        .text_held = @ptrCast(&current.text_held),
        .written = @ptrCast(&current.written),
    };
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
    const current = self.row(index);

    const input: Input = .{
        .function_index = index,
        .source = &source,
        .environment = &environment,
        .facts = if (saved != null) &facts else null,
        .held = self.flow.held,
        .text_held = self.flow.text_held,
        .written = self.flow.written,
        .current = &current,
        .target = &target(std.meta.Child(@FieldType(Input, "target")), &current),
    };

    return zx.columns.invoke(generated.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
