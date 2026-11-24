const std = @import("std");
const compiler = @import("compiler");
const model = @import("../../package/manifest/model.zig");
const Inputs = @import("watch_inputs").Inputs;
const State = @import("scopes/state.zig");
const rule = @import("cli_source").native_scope_load;
pub const NativeSettings = @import("scopes/publish.zig").NativeSettings;
pub const Result = State.Result;

pub fn load(io: std.Io, allocator: std.mem.Allocator, scopes: []compiler.project.PackageScope, manifests: []const model.Manifest, owner: usize, inputs: ?*Inputs) !Result {
    var registry_memory = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer registry_memory.deinit();

    var state: State = .{
        .io = io,
        .allocator = allocator,
        .inputs = inputs,
        .scopes = scopes,
        .manifests = manifests,
        .entry_root = scopes[owner].root,
        .registry_owner = registry_memory.allocator(),
    };

    defer state.close();

    const reference = &state;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    var position = [1]u64{0};
    const index: []u64 = &position;

    rule.executeIn(scratch.allocator(), &.{
        .frame = @ptrCast(&reference),
        .count = scopes.len,
        .index = @ptrCast(&index),
    }) catch |err| return state.failure.unwrap(err);

    return state.take(manifests[owner]);
}
