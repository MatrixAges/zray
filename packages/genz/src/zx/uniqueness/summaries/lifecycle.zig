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
        const storage = summaries.storage.?;

        return .{
            .layout = zx.columns.view(Layout, storage.layout),
            .guarantees = storage.guarantees,
            .demands = storage.demands,
        };
    }

    pub fn input(self: *const Borrowed, mode: Mode, active: []const bool, known: []const bool) Input {
        return .{
            .mode = mode,
            .layout = &self.layout,
            .active = active,
            .known = known,
        };
    }
};

pub fn apply(summaries: Summaries, mode: Mode, active: []const bool, known: []const bool) void {
    const state = Borrowed.init(&summaries);
    const input = state.input(mode, active, known);
    var scratch_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const cells = zx.columns.invoke(applying.executeValue, fallback.allocator(), &input) catch |err| {
        std.debug.panic("summary lifecycle failed: {s}", .{@errorName(err)});
    };

    const target = if (mode == .ClearWants) state.demands else state.guarantees;

    @memcpy(target, cells);
}
