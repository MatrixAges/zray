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

fn copyRow(dest: []bool, src: []const bool) void {
    if (dest.ptr != src.ptr) @memcpy(dest, src);
}

pub fn adopt(self: *const Self, index: u32, cached: Memo.Flowed) bool {
    const entry = @import("generated_uniqueness_flow_adopt");
    const Adoption = std.meta.Child(entry.Input);
    const current = self.row(index);

    const input: Adoption = .{
        .current = zx.columns.pointer(@FieldType(Adoption, "current"), &current),
        .cached = &.{ .held = cached.held, .text_held = cached.text_held, .written = cached.written },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const ok = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    if (ok) {
        copyRow(self.flow.mutable.held[index], cached.held);
        copyRow(self.flow.mutable.text_held[index], cached.text_held);
        copyRow(self.flow.mutable.written[index], cached.written);
    }

    return ok;
}

fn row(self: *const Self, index: u32) Current {
    const flow = self.flow;

    return .{ .held = flow.held[index], .text_held = flow.text_held[index], .written = flow.written[index] };
}

fn workspace(self: *Self) std.mem.Allocator {
    if (self.scratch == null) self.scratch = .init(self.allocator);

    const scratch = &self.scratch.?;

    _ = scratch.reset(.retain_capacity);

    return scratch.allocator();
}

pub fn keep(self: *Self, owner: std.mem.Allocator, view: Body.View) std.mem.Allocator.Error!*const Body.Facts {
    return Body.keep(owner, self.workspace(), view, self.slots);
}

pub fn visit(self: *Self, index: u32, view: Body.View, saved: ?*const Body.Facts) std.mem.Allocator.Error!bool {
    const slots = self.slots;
    const layout = Layout{ .offsets = slots.offsets, .members = @ptrCast(slots.members), .unwrapped = @ptrCast(slots.unwrapped) };
    const environment = Environment{ .layout = &layout, .type_kinds = slots.types.kinds, .type_first = slots.types.first, .counts = slots.counts };
    const source = Body.source(std.meta.Child(@FieldType(Input, "source")), view);
    var current = self.row(index);

    const input: Input = .{
        .function_index = index,
        .source = &source,
        .environment = &environment,
        .facts = if (saved) |facts|
            zx.columns.pointer(std.meta.Child(@FieldType(Input, "facts")), facts)
        else
            null,
        .held = self.flow.held,
        .text_held = self.flow.text_held,
        .written = self.flow.written,
        .current = &current,
    };

    const res = zx.columns.invoke(generated.executeValue, self.workspace(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    copyRow(self.flow.mutable.held[index], res.held);
    copyRow(self.flow.mutable.text_held[index], res.text_held);
    copyRow(self.flow.mutable.written[index], res.written);

    return res.changed;
}
