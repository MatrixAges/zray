const std = @import("std");
const zx = @import("zx");
const state = @import("../state.zig");

pub fn render(allocator: std.mem.Allocator, objects: state.ObjectColumns, requirements: state.Requirements, execute: bool) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var writer: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer writer.deinit();

    const entry = @import("generated_store_state");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const view = objects.bind(std.meta.Child(@FieldType(Input, "objects")));

    const input: Input = .{
        .objects = &view,
        .execute = execute,
        .io = requirements.io,
        .process = requirements.process,
    };

    const result = entry.executeValue(arena.allocator(), if (indirect) &input else input) catch |err| return failure(err);

    try @import("../../printer/module.zig").writeGroups(&writer, result orelse return error.OutOfMemory);

    return writer.finish();
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid State module AST"),
    };
}
