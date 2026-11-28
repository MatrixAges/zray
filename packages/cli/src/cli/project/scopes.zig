const std = @import("std");
const compiler = @import("compiler");
const model = @import("../../package/manifest/model.zig");
const Inputs = @import("watch_inputs").Inputs;
const State = @import("scopes/state.zig");
const rule = @import("cli_source").native_scope_load;
const memory = @import("zx").memory;
const name_workspace_size = 1024;
pub const NativeSettings = State.NativeSettings;
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
    var buffer: [name_workspace_size]u8 = undefined;
    var first = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var scratch = std.heap.ArenaAllocator.init(first.allocator());
    var active: memory.ArenaScope = .{ .active = scratch.allocator() };

    defer scratch.deinit();

    state.workspace = .{
        .externals = &state.external_rows,
        .external_modules = @ptrCast(&state.external_modules),
        .interfaces = &state.interface_rows,
        .modules = &state.module_rows,
        .binding = &state.binding,
        .traversal = &state.traversal,
        .declarations = &state.declaration_views.view,
    };

    state.binding = .{ .window = &state.window, .registry = &state.registry_view, .library = &state.compiled_view };
    state.active = &active;
    state.scratch = scratch.allocator();

    state.traversal = .{
        .binding = &state.binding,
        .sources = &state.module_sources,
        .row = 0,
        .aliases = &state.alias_input,
        .status = .Valid,
    };

    const status = rule.executeIn(active.allocator(), &.{
        .frame = @ptrCast(&reference),
        .count = scopes.len,
        .row = 0,
        .workspace = &state.workspace,
        .status = .Valid,
    }) catch |err| {
        if (state.alias_active and (err == error.Overflow or err == error.IntegerOverflow)) return error.OutOfMemory;

        return state.failure.unwrap(err);
    };

    switch (status) {
        .Valid => return state.take(manifests[owner]),
        .InvalidSpecifier => return error.InvalidSpecifier,
        .InvalidExternalSpecifier => return error.InvalidExternalSpecifier,
        .InvalidNativeInterfacePath => return error.InvalidNativeInterfacePath,
        .InvalidNativeModule => return error.InvalidNativeModule,
        .ReservedNativeModule => return error.ReservedNativeModule,
        .DuplicateNativeModule => return error.DuplicateNativeModule,
        .UnknownNativeDependency => return error.UnknownNativeDependency,
        .ConflictingNativeAbiAlias => return error.ConflictingNativeAbiAlias,
        .UnknownNativeAbiAlias => return error.UnknownNativeAbiAlias,
    }
}
