const std = @import("std");
const zx = @import("zx");
const Native = @import("../../interface.zig").Native;
const Loaded = @import("../../native.zig");
const Artifact = @import("../../artifact/model.zig");
const restoring = @import("../native_restore.zig");
const generated = @import("generated_native_restore");
const Input = @import("native_input.zig");
const Target = @import("native_publish.zig");

pub fn restore(allocator: std.mem.Allocator, artifact: *const Artifact.Module, entry: Native, current: restoring.Current, admitted: bool) restoring.Error!Loaded.Result {
    var arena = std.heap.ArenaAllocator.init(current.backing);
    var buffer: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    var input: Input = undefined;
    var target: Target = undefined;
    var scope: zx.memory.ArenaScope = .{ .active = scratch.allocator() };

    target.init(allocator, &scope, artifact, current);
    input.init(artifact, entry, current, admitted, &target.input);
    errdefer target.release(allocator);

    const status = generated.executeIn(scope.allocator(), &input.input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (status) {
        .Ready => {},
        .InvalidModule => return error.InvalidModule,
        .InvalidIr => return error.InvalidIr,
        .MissingNominalOrigin => return error.MissingNominalOrigin,
        .ConflictingNominalType => return error.ConflictingNominalType,
        .Full => return error.OutOfMemory,
    }

    return .{
        .types = current.types.view(),
        .exports = @ptrCast(target.exports),
        .members = target.functions.members(),
    };
}
