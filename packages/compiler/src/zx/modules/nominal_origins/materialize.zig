const std = @import("std");
const zx = @import("zx");
const data = @import("nominal_data");
const generated = @import("generated_origin_materialization");
const release = @import("generated_origin_materialization_release");
const Input = std.meta.Child(generated.Input);

/// A null labels slice preserves and owns the original names for library admission.
pub fn append(allocator: std.mem.Allocator, target: *data.Storage, source: data.Table, labels: ?[]const []const u8, own_origins: bool) std.mem.Allocator.Error!void {
    const count = source.count();

    if (count == 0 and source.kinds.len == 0 and source.owners.len == 0 and
        source.members.len == 0 and source.names.len == 0) return;

    const name_count = if (labels == null) source.names.len else count;

    try target.ids.ensureUnusedCapacity(allocator, count);
    try target.kinds.ensureUnusedCapacity(allocator, source.kinds.len);
    try target.owners.ensureUnusedCapacity(allocator, source.owners.len);
    try target.members.ensureUnusedCapacity(allocator, source.members.len);
    try target.names.ensureUnusedCapacity(allocator, name_count);

    var owners = target.owners.unusedCapacitySlice()[0..source.owners.len];
    var members = target.members.unusedCapacitySlice()[0..source.members.len];
    var names = target.names.unusedCapacitySlice()[0..name_count];
    const origins = data.Table.borrow(std.meta.Child(@FieldType(Input, "source")), source);
    var completed: [1]u64 = .{0};
    var progress: []u64 = &completed;

    const input: Input = .{
        .allocator = @ptrCast(&allocator),
        .source = &origins,
        .names = source.names,
        .labels = labels,
        .own_origins = own_origins,
        .owners_out = @ptrCast(&owners),
        .members_out = @ptrCast(&members),
        .names_out = @ptrCast(&names),
        .progress = @ptrCast(&progress),
    };

    errdefer {
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        release.executeIn(scratch.allocator(), &input) catch unreachable;
    }

    zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (!own_origins) {
        @memcpy(owners, source.owners);
        @memcpy(members, source.members);
    }

    target.ids.appendSliceAssumeCapacity(source.ids);
    target.kinds.appendSliceAssumeCapacity(source.kinds);

    _ = target.owners.addManyAsSliceAssumeCapacity(owners.len);
    _ = target.members.addManyAsSliceAssumeCapacity(members.len);
    _ = target.names.addManyAsSliceAssumeCapacity(names.len);
}
