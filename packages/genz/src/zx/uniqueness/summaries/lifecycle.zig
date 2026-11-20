const std = @import("std");
const zx = @import("zx");
const Summaries = @import("../summaries.zig");
const applying = @import("generated_uniqueness_summaries_lifecycle");
const Input = std.meta.Child(applying.Input);
const Layout = std.meta.Child(@FieldType(Input, "layout"));
pub const Mode = @FieldType(Input, "mode");

pub const Borrowed = struct {
    layout: Layout,
    guarantees: []u8,
    demands: []u8,
    pub fn init(summaries: *const Summaries) Borrowed {
        const storage = &summaries.storage.?;

        return .{
            .layout = zx.columns.view(Layout, storage.layout),
            .guarantees = @constCast(storage.guarantees),
            .demands = @constCast(storage.demands),
        };
    }

    pub fn input(self: *const Borrowed, mode: Mode, native_modules: []const ?u32, known: []const bool) Input {
        return .{
            .mode = mode,
            .layout = &self.layout,
            .guarantees = @ptrCast(&self.guarantees),
            .demands = @ptrCast(&self.demands),
            .native_modules = native_modules,
            .known = known,
        };
    }
};

pub fn apply(summaries: Summaries, mode: Mode, native_modules: []const ?u32, known: []const bool) void {
    const state = Borrowed.init(&summaries);
    const input = state.input(mode, native_modules, known);
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(applying.executeValue, memory.allocator(), &input) catch |err| {
        std.debug.panic("summary lifecycle failed: {s}", .{@errorName(err)});
    };
}
