const std = @import("std");
const State = @import("state.zig");
const Fields = @import("fields.zig");
const object = @import("object.zig");
const Value = @import("../initializer.zig").Value;

pub fn run(state: *State) std.mem.Allocator.Error!Value {
    const options = state.options;
    var ranges = Fields.init(&options.layout, options.first);

    try state.prepare(ranges.count, true);

    var cursor: usize = 0;
    var invalid_link = false;

    while (ranges.next()) |range| {
        for (range.first..range.end, cursor..) |row, position| {
            try state.openField(row);

            defer state.releaseField();

            if (!try state.compileField()) return .{ .diagnostic = state.diagnostic.? };
            try state.recordField(position, true);
            if (!invalid_link) invalid_link = !try state.linkField(position);
        }

        cursor += range.end - range.first;
    }

    publish(state, invalid_link) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = try state.report() };
    };

    return .{ .program = state.program };
}

fn publish(state: *State, invalid_link: bool) @import("zx").Error!void {
    try state.resolveType();
    if (invalid_link) return state.invalidLink();

    const root = try object.append(&state.builder, state.output, state.names, state.table.?.get(state.output).object.names, state.evaluation, State.span);

    try state.finishProgram(root);
    try state.analyzeOwnership();
    try state.verifyProgram();
}
