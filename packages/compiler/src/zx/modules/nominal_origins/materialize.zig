const std = @import("std");
const data = @import("nominal_data");
const generated = @import("generated_origin_materialization");
const release = @import("generated_origin_materialization_release");
const Input = std.meta.Child(generated.Input);
const State = std.meta.Child(@FieldType(generated.zx_pending, "store_0"));
const Error = std.mem.Allocator.Error;

const StoreHost = struct {
    store_0: *State,
    allocator: std.mem.Allocator,
    owners: [][]const u8,
    members: [][]const u8,
    names: [][]const u8,
    completed: u64 = 0,
    owned_names: bool = false,
    pub fn commit(self: *StoreHost, pending: anytype) Error!void {
        const next = pending.store_0 orelse return;

        const target = switch (next.column) {
            .Owners => self.owners,
            .Members => self.members,
            .Names => self.names,
        };

        if (next.own) {
            var copied: usize = 0;

            errdefer for (target[0..copied]) |text| self.allocator.free(text);

            for (next.source, target) |text, *slot| {
                slot.* = try self.allocator.dupe(u8, text);
                copied += 1;
            }

            switch (next.column) {
                .Owners, .Members => self.completed += 1,
                .Names => self.owned_names = true,
            }
        } else {
            @memcpy(target, next.source);
        }
    }
};

/// A null labels slice preserves and owns the original names for library admission.
pub fn append(allocator: std.mem.Allocator, target: *data.Storage, source: data.Table, labels: ?[]const []const u8, own_origins: bool) Error!void {
    const count = source.count();

    if (count == 0 and source.kinds.len == 0 and source.owners.len == 0 and
        source.members.len == 0 and source.names.len == 0) return;

    const name_count = if (labels == null) source.names.len else count;

    try target.ids.ensureUnusedCapacity(allocator, count);
    try target.kinds.ensureUnusedCapacity(allocator, source.kinds.len);
    try target.owners.ensureUnusedCapacity(allocator, source.owners.len);
    try target.members.ensureUnusedCapacity(allocator, source.members.len);
    try target.names.ensureUnusedCapacity(allocator, name_count);

    const origins = data.Table.borrow(std.meta.Child(@FieldType(Input, "source")), source);
    const state: std.meta.Child(State) = .{ .column = .Owners, .source = &.{}, .own = false };
    var state_ptr: State = &state;

    var host: StoreHost = .{
        .store_0 = &state_ptr,
        .allocator = allocator,
        .owners = target.owners.unusedCapacitySlice()[0..source.owners.len],
        .members = target.members.unusedCapacitySlice()[0..source.members.len],
        .names = target.names.unusedCapacitySlice()[0..name_count],
    };

    const input: Input = .{ .source = &origins, .names = source.names, .labels = labels, .own_origins = own_origins };
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    errdefer {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const cleanup = release.executeValue(empty.allocator(), host.completed) catch unreachable;

        if (cleanup != .None) for (host.owners) |owner| allocator.free(owner);
        if (cleanup == .OwnersAndMembers) for (host.members) |member| allocator.free(member);
        if (host.owned_names) for (host.names) |name| allocator.free(name);
    }

    generated.executeIn(scratch.allocator(), &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    target.ids.appendSliceAssumeCapacity(source.ids);
    target.kinds.appendSliceAssumeCapacity(source.kinds);

    _ = target.owners.addManyAsSliceAssumeCapacity(host.owners.len);
    _ = target.members.addManyAsSliceAssumeCapacity(host.members.len);
    _ = target.names.addManyAsSliceAssumeCapacity(host.names.len);
}
