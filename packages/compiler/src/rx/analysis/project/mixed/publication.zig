const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Source = @import("frontend").project.artifact.source_link;
pub const Plan = struct { visible: usize, entry: ?ir.FunctionId };

pub fn entry(table: *const ir.FunctionTable, loaded: *const Source.Loaded, orchestration: bool, exports: bool) Plan {
    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_mixed_entry");

        const input: std.meta.Child(rule.Input) = .{
            .function = if (loaded.function) |id| @backingInt(id) else null,
            .natives = table.native_modules,
            .rx = orchestration,
            .has_exports = exports,
            .has_members = loaded.members.len != 0,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{
            .visible = @intCast(result.visible),
            .entry = if (result.entry) |id| @fromBackingInt(id) else null,
        };
    }

    const count = table.count();
    const id = loaded.function orelse return .{ .visible = count, .entry = null };
    const row = @backingInt(id);
    const visible = if (orchestration and !exports and loaded.members.len == 0) row else count;

    return .{ .visible = visible, .entry = if (row < visible and table.native_modules[row] == null) id else null };
}
