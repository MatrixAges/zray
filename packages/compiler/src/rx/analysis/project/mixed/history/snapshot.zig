const std = @import("std");
const State = @import("../state.zig");
const Checkpoint = @import("../../history.zig").Checkpoint;
const columns = @import("../../history/columns.zig");
const Start = std.meta.Child(@import("generated_rx_mixed_history_start").Input);
const Input = std.meta.Child(@FieldType(Start, "capture"));
pub const Extent = std.meta.Child(@FieldType(Input, "extent"));

pub const Storage = struct {
    types: [@typeInfo(@FieldType(Checkpoint, "types")).array.len]u64,
    origins: [@typeInfo(@FieldType(Checkpoint, "origins")).array.len]u64,
    extent: Extent,
    pub fn bind(self: *Storage, state: *State) Input {
        self.types = columns.measureAs(u64, &state.types.items);
        self.origins = columns.measureAs(u64, &state.types.origins.items);

        self.extent = .{
            .functions = state.functions.count(),
            .native_modules = state.native_modules.count(),
            .initializers = state.initializers.items.len,
            .libraries = state.libraries.count(),
        };

        return .{ .types = &self.types, .origins = &self.origins, .extent = &self.extent };
    }
};

pub fn writeSeed(state: *const State, target: *Checkpoint) void {
    target.* = .{
        .types = columns.measure(&state.types.items),
        .origins = columns.measure(&state.types.origins.items),
        .functions = state.functions.count(),
        .native_modules = state.native_modules.count(),
        .initializers = state.initializers.items.len,
        .libraries = state.libraries.count(),
    };
}

pub fn commit(target: *Checkpoint, words: []const u64) void {
    const destination = std.mem.bytesAsSlice(usize, std.mem.asBytes(target));

    for (destination, words) |*slot, value| slot.* = @intCast(value);
}
