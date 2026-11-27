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
    const type_ids = try temp.alloc(u32, artifact.types.count());

    target.init(allocator, current);
    input.init(artifact, entry, current, admitted, type_ids);
    errdefer target.tail.release();

    const prepared = generated.executeIn(temp, &input.input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    try mapStatus(prepared.status);

    const value = prepared.value orelse return error.InvalidModule;

    const publish_input: PublishInput = .{
        .types = try zx.columns.bridge(@FieldType(PublishInput, "types"), temp, value.types),
        .origins = try zx.columns.bridge(@FieldType(PublishInput, "origins"), temp, value.origins),
        .mapping = try zx.columns.bridge(@FieldType(PublishInput, "mapping"), temp, value.mapping),
        .signatures = try zx.columns.bridge(@FieldType(PublishInput, "signatures"), temp, &input.signatures),
        .exported = try zx.columns.bridge(@FieldType(PublishInput, "exported"), temp, &input.exports),
        .namespace = entry.namespace,
        .destination = zx.columns.pointer(@FieldType(PublishInput, "destination"), @as(*const @TypeOf(target.tail.target), &target.tail.target)),
        .members = &target.members,
        .module = @backingInt(current.module),
    };

    const published = publishing.executeIn(allocator, &publish_input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    try mapStatus(published.status);

    return target.commit(allocator, current, published.installation orelse unreachable);
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
