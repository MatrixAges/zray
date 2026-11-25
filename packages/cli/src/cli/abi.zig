const std = @import("std");
const compiler = @import("compiler");
const effects = @import("sources/effects.zig");
const input = @import("abi/input.zig");
const memory = @import("zx").memory;
const view = compiler.zig.abi_view;
const Loaded = @import("project.zig").Loaded;
const rule = @import("cli_source").render_bundle_abi;
const Request = std.meta.Child(rule.Input);
const Columns = std.meta.Child(@FieldType(Request, "files"));
const host = @import("cli_abi").native.@"zig:bundle_abi_host";
const fields = .{ .modules = "module", .names = "name", .paths = "path", .sources = "source" };

pub const File = struct { module: []const u8, name: []const u8, path: []const u8, source: []const u8 };
pub const Result = struct { source: []const u8, views: []const File = &.{} };

const State = struct {
    owner: std.mem.Allocator,
    temporary: std.mem.Allocator,
    type_names: []const []const u8,
    native_modules: compiler.ir.NativeModuleTable,
    modules: []const compiler.zig.ModuleFile,
    loaded: *const Loaded,
    rows: []File = &.{},
    borrowed: input.Borrowed = undefined,
    plan: input.Input = undefined,
    fields: @TypeOf(memory.borrowWriteFields(fields, @as([]File, &.{}))) = undefined,
    columns: Columns = undefined,
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

    const source = rule.executeIn(state.temporary, &.{
        .frame = @ptrCast(&reference),
        .source = bundle.types,
        .identities = bundle.native_modules.identities,
        .plan = &state.plan,
        .files = &state.columns,
        .owner = @ptrCast(&state.owner),
    }) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.ConflictingNativeAbiAlias, error.NativeModuleNameConflict => err,
        else => unreachable,
    };

    return .{ .source = source, .views = state.rows };
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

pub fn reserveAbiFiles(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const state = effects.state(State, handle);

    state.rows = try state.owner.alloc(File, @intCast(count));
    state.fields = memory.borrowWriteFields(fields, state.rows);
    state.columns = state.fields.bind(Columns);
}

pub fn renderAbiFile(handle: *const anyopaque, aliases: []const host.AbiAlias) std.mem.Allocator.Error![]const u8 {
    const state = effects.state(State, handle);

    return view.renderBorrowed(state.owner, state.type_names, aliases, true);
}

pub fn renderAbiRoot(handle: *const anyopaque, canonical: []const u8, aliases: []const host.AbiAlias) std.mem.Allocator.Error![]const u8 {
    const state = effects.state(State, handle);

    return view.renderRootBorrowed(state.owner, canonical, aliases);
}
