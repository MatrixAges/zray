const std = @import("std");
const zx = @import("zx");
const Native = @import("../../interface.zig").Native;
const Loaded = @import("../../native.zig");
const Artifact = @import("../../artifact/model.zig");
const restoring = @import("../native_restore.zig");
const generated = @import("generated_native_restore");
const publishing = @import("generated_native_restore_publish");
const Input = @import("native_input.zig");
const Target = @import("native_publish.zig");
const PublishInput = std.meta.Child(publishing.Input);

pub fn restore(allocator: std.mem.Allocator, artifact: *const Artifact.Module, entry: Native, current: restoring.Current, admitted: bool) restoring.Error!Loaded.Result {
    var arena = std.heap.ArenaAllocator.init(current.backing);
    var buffer: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    var input: Input = undefined;
    var target: Target = undefined;
    const temp = scratch.allocator();

    target.init(allocator, artifact, current);
    input.init(artifact, entry, current, admitted);
    errdefer target.release(allocator);

    const prepared = generated.executeIn(temp, &input.input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    try mapStatus(prepared.status);

    const value = prepared.value orelse return error.InvalidModule;

    const publish_input: PublishInput = .{
        .types = try zx.columns.bridge(@FieldType(PublishInput, "types"), temp, value.types),
        .origins = try zx.columns.bridge(@FieldType(PublishInput, "origins"), temp, value.origins),
        .mapping = try zx.columns.bridge(@FieldType(PublishInput, "mapping"), temp, &input.mapping),
        .signatures = try zx.columns.bridge(@FieldType(PublishInput, "signatures"), temp, &input.signatures),
        .exported = try zx.columns.bridge(@FieldType(PublishInput, "exported"), temp, &input.exports),
        .namespace = entry.namespace,
        .target = &target.input,
    };

    const status = publishing.executeIn(allocator, &publish_input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    try mapStatus(status);

    return .{
        .types = current.types.view(),
        .exports = @ptrCast(target.exports),
        .members = target.functions.members(),
    };
}

fn mapStatus(status: anytype) restoring.Error!void {
    return switch (status) {
        .Ready => {},
        .InvalidModule => error.InvalidModule,
        .InvalidIr => error.InvalidIr,
        .MissingNominalOrigin => error.MissingNominalOrigin,
        .ConflictingNominalType => error.ConflictingNominalType,
        .Full => error.OutOfMemory,
    };
}
