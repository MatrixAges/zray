const std = @import("std");
const zx = @import("zx");
const State = @import("../state.zig");
const Checkpoint = @import("../../history.zig").Checkpoint;
const columns = @import("../../history/columns.zig");
const Start = std.meta.Child(@import("generated_rx_mixed_history_start").Input);
const Input = std.meta.Child(@FieldType(Start, "capture"));
pub const Extent = std.meta.Child(@FieldType(Input, "extent"));
const memory = zx.memory;

pub const Storage = struct {
    type_slots: [@typeInfo(@FieldType(Checkpoint, "types")).array.len]*usize,
    origin_slots: [@typeInfo(@FieldType(Checkpoint, "origins")).array.len]*usize,
    types: memory.ColumnLengths,
    origins: memory.ColumnLengths,
    extent: Extent,
    target: memory.WriteColumn,
    pub fn bind(self: *Storage, state: *const State, target: *Checkpoint) Input {
        self.type_slots = memory.borrowColumnLengths(@constCast(&state.types.items));
        self.origin_slots = memory.borrowColumnLengths(@constCast(&state.types.origins.items));
        self.types = &self.type_slots;
        self.origins = &self.origin_slots;

        self.extent = .{
            .functions = state.functions.count(),
            .native_modules = state.native_modules.count(),
            .initializers = state.initializers.items.len,
            .libraries = state.libraries.count(),
        };

        self.target = columns.wordTarget(std.mem.asBytes(target));

        return .{ .types = @ptrCast(&self.types), .origins = @ptrCast(&self.origins), .extent = &self.extent, .target = @ptrCast(&self.target) };
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
