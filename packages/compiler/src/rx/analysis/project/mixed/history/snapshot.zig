const std = @import("std");
const zx = @import("zx");
const State = @import("../state.zig");
const Checkpoint = @import("../../history.zig").Checkpoint;
const seed = @import("../../history/columns.zig");

pub fn write(state: *const State, target: *Checkpoint) void {
    if (comptime !@import("rx_options").generated_graph) {
        target.* = .{
            .types = seed.measure(&state.types.items),
            .origins = seed.measure(&state.types.origins.items),
            .functions = state.functions.count(),
            .native_modules = state.native_modules.count(),
            .initializers = state.initializers.items.len,
            .libraries = state.libraries.count(),
        };

        return;
    }

    const generated = @import("generated_rx_history_snapshot");
    const Input = std.meta.Child(generated.Input);
    const memory = zx.memory;
    const type_slots = memory.borrowColumnLengths(@constCast(&state.types.items));
    const origin_slots = memory.borrowColumnLengths(@constCast(&state.types.origins.items));
    const types: memory.ColumnLengths = &type_slots;
    const origins: memory.ColumnLengths = &origin_slots;
    const word = @sizeOf(usize);

    comptime {
        const first = (@typeInfo(@FieldType(Checkpoint, "types")).array.len + @typeInfo(@FieldType(Checkpoint, "origins")).array.len) * word;

        if (@offsetOf(Checkpoint, "types") != 0 or
            @offsetOf(Checkpoint, "origins") != @sizeOf(@FieldType(Checkpoint, "types")) or
            @offsetOf(Checkpoint, "functions") != first or
            @offsetOf(Checkpoint, "native_modules") != first + word or
            @offsetOf(Checkpoint, "initializers") != first + 2 * word or
            @offsetOf(Checkpoint, "libraries") != first + 3 * word or
            @sizeOf(Checkpoint) != first + 4 * word)
        {
            @compileError("History checkpoint must match the sequence of native words");
        }
    }

    const output: memory.WriteColumn = .{
        .items = @ptrCast(target),
        .count = @sizeOf(Checkpoint) / word,
        .stride = word,
        .width = word,
    };

    const input: Input = .{
        .types = @ptrCast(&types),
        .origins = @ptrCast(&origins),
        .extent = &.{
            .functions = state.functions.count(),
            .native_modules = state.native_modules.count(),
            .initializers = state.initializers.items.len,
            .libraries = state.libraries.count(),
        },
        .target = @ptrCast(&output),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(generated.executeValue, scratch.allocator(), &input) catch unreachable;
}
