const std = @import("std");
const compiler = @import("compiler");
const effects = @import("sources/effects.zig");
const input = @import("abi/input.zig");
const view = compiler.zig.abi_view;
const Loaded = @import("project.zig").Loaded;
const rule = @import("cli_source").render_bundle_abi;
const host = @import("cli_abi").native.@"zig:bundle_abi_host";
pub const File = struct { module: []const u8, name: []const u8, path: []const u8, source: []const u8 };
pub const Result = struct { source: []const u8, views: []const File = &.{} };

const State = struct {
    owner: std.mem.Allocator,
    temporary: std.mem.Allocator,
    type_names: []const []const u8,
    native_modules: compiler.ir.NativeModuleTable,
    modules: []const compiler.zig.ModuleFile,
    loaded: *const Loaded,
    borrowed: input.Borrowed = undefined,
    plan: input.Input = undefined,
};

pub fn create(allocator: std.mem.Allocator, bundle: anytype, loaded: *const Loaded) !Result {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var state: State = .{
        .owner = allocator,
        .temporary = buffered.allocator(),
        .type_names = bundle.type_names,
        .native_modules = bundle.native_modules,
        .modules = bundle.modules,
        .loaded = loaded,
    };

    const reference = &state;

    const rendered = rule.executeIn(state.temporary, &.{
        .frame = @ptrCast(&reference),
        .source = bundle.types,
        .identities = bundle.native_modules.identities,
        .plan = &state.plan,
    }) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.ConflictingNativeAbiAlias, error.NativeModuleNameConflict => err,
        else => unreachable,
    };

    const views = try allocator.alloc(File, rendered.views.len);

    for (rendered.views, views) |item, *slot| {
        slot.* = .{
            .module = item.module,
            .name = try allocator.dupe(u8, item.name),
            .path = try allocator.dupe(u8, item.path),
            .source = item.source,
        };
    }

    return .{ .source = rendered.source, .views = views };
}

pub fn borrowAbiInputs(handle: *const anyopaque) void {
    const state = effects.state(State, handle);
    state.plan = state.borrowed.init(state.native_modules, state.modules, state.loaded);
}

pub fn rejectAbiPlan(conflict: host.AbiConflict) error{ ConflictingNativeAbiAlias, NativeModuleNameConflict }!void {
    return switch (conflict) {
        .Alias => error.ConflictingNativeAbiAlias,
        .Name => error.NativeModuleNameConflict,
    };
}

pub fn renderAbiFile(handle: *const anyopaque, aliases: []const host.AbiAlias) std.mem.Allocator.Error![]const u8 {
    const state = effects.state(State, handle);

    return view.renderBorrowed(state.owner, state.type_names, aliases, true);
}

pub fn renderAbiRoot(handle: *const anyopaque, canonical: []const u8, aliases: []const host.AbiAlias) std.mem.Allocator.Error![]const u8 {
    const state = effects.state(State, handle);

    return view.renderRootBorrowed(state.owner, canonical, aliases);
}
