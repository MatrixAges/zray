const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Inputs = @import("watch_inputs").Inputs;
const Text = @import("../sources/text.zig");
const refs = @import("preparation/references.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").prepare_rx_types;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub const Options = struct {
    io: std.Io,
    project: compiler.project.Options,
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource = &.{},
    functions: []const rx.TextSource,
    writer: *std.Io.Writer,
    inputs: ?*Inputs = null,
    texts: ?*Text.Cache = null,
};

const State = struct {
    options: *const Options,
    cursor: *refs.Cursor,
    result: std.ArrayList(rx.TextSource) = .empty,
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

pub fn collect(allocator: std.mem.Allocator, options: Options) !?[]const rx.TextSource {
    var cursor: refs.Cursor = .{
        .allocator = allocator,
        .io = options.io,
        .project = options.project,
        .modules = options.modules,
        .stores = options.stores,
        .writer = options.writer,
        .inputs = options.inputs,
    };

    var state: State = .{ .options = &options, .cursor = &cursor };

    try state.result.appendSlice(allocator, options.functions);

    const initial_paths = try allocator.alloc([]const u8, options.functions.len);

    for (options.functions, 0..) |source, index| {
        initial_paths[index] = try std.fs.path.resolve(allocator, &.{ options.project.root_dir, source.path });
    }

    const reference = &state;
    const references = &cursor;

    defer cursor.deinit();

    var store_arena = std.heap.ArenaAllocator.init(allocator);

    defer store_arena.deinit();

    var visited: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &visited };

    const valid = rule.execute(&store_arena, &.{
        .types = @ptrCast(&reference),
        .references = @ptrCast(&references),
        .module_count = options.modules.len + options.stores.len,
        .scoped = options.project.package_scopes.len != 0,
        .initial_paths = initial_paths,
    }, &host) catch |err| return cursor.failure.unwrap(err);

    return if (valid) state.result.items else null;
}

pub fn validateTypeSourceFile(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const cursor = self.cursor;

    if (cursor.inputs) |inputs| inputs.add(cursor.io, path) catch |err| return cursor.failure.save(err);
    @import("../../package/source.zig").validateWithInputs(cursor.io, cursor.allocator, path, cursor.project.package_scopes, cursor.inputs) catch |err| return cursor.failure.save(err);
}

pub fn validateTypeSourceRoot(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const cursor = self.cursor;
    const io = cursor.io;
    const allocator = cursor.allocator;
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, cursor.project.root_dir, allocator) catch |err| return cursor.failure.save(err);
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| return cursor.failure.save(err);
    const relative = std.fs.path.relative(allocator, root, null, root, real) catch |err| return cursor.failure.save(err);

    if (@import("collection.zig").outside(relative)) return cursor.failure.save(error.RxSourceOutsideProject);
}

pub fn readPreparedTypeSource(handle: *const anyopaque, index: u64, path: []const u8) Error!bool {
    const self = State.get(handle);
    const cursor = self.cursor;
    const allocator = cursor.allocator;

    const text = Text.read(cursor.io, allocator, path, self.options.texts) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return cursor.failure.save(err);

        try cursor.report(@intCast(index), @errorName(err));

        return false;
    };

    if (text.fresh) if (cursor.inputs) |inputs| inputs.record(cursor.io, path, text.bytes) catch |err| return cursor.failure.save(err);

    self.result.append(allocator, .{ .path = path, .source = text.bytes }) catch |err| return cursor.failure.save(err);

    return true;
}
