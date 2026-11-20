const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Inputs = @import("watch_inputs").Inputs;
const Text = @import("../sources/text.zig");
const refs = @import("preparation/references.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").prepare_rx_types;

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
    seen: std.StringHashMapUnmanaged(void) = .empty,
    path: []const u8 = undefined,
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
    const reference = &state;
    const references = &cursor;

    defer state.seen.deinit(allocator);

    const valid = rule.executeIn(allocator, &.{
        .types = @ptrCast(&reference),
        .references = @ptrCast(&references),
    }) catch |err| return cursor.failure.unwrap(err);

    return if (valid) state.result.items else null;
}

pub fn copyInitialTypeSources(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);
    const cursor = self.cursor;
    const functions = self.options.functions;

    self.result.appendSlice(cursor.allocator, functions) catch |err| return cursor.failure.save(err);

    return functions.len;
}

pub fn registerInitialTypeSource(handle: *const anyopaque, index: u64) Error!void {
    const self = State.get(handle);
    const cursor = self.cursor;
    const source = &self.options.functions[@intCast(index)];
    const path = std.fs.path.resolve(cursor.allocator, &.{ cursor.project.root_dir, source.path }) catch |err| return cursor.failure.save(err);

    self.seen.put(cursor.allocator, path, {}) catch |err| return cursor.failure.save(err);
}

pub fn selectTypeSourcePath(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const cursor = self.cursor;

    self.path = std.fs.path.resolve(cursor.allocator, &.{ cursor.project.root_dir, cursor.target.source }) catch |err| return cursor.failure.save(err);

    return !self.seen.contains(self.path);
}

pub fn validateTypeSourceFile(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const cursor = self.cursor;
    const path = self.path;

    if (cursor.inputs) |inputs| inputs.add(cursor.io, path) catch |err| return cursor.failure.save(err);
    @import("../../package/source.zig").validateWithInputs(cursor.io, cursor.allocator, path, cursor.project.package_scopes, cursor.inputs) catch |err| return cursor.failure.save(err);
}

pub fn hasTypeSourceScopes(handle: *const anyopaque) bool {
    return State.get(handle).cursor.project.package_scopes.len != 0;
}

pub fn validateTypeSourceRoot(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const cursor = self.cursor;
    const io = cursor.io;
    const allocator = cursor.allocator;
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, cursor.project.root_dir, allocator) catch |err| return cursor.failure.save(err);
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, self.path, allocator) catch |err| return cursor.failure.save(err);
    const relative = std.fs.path.relative(allocator, root, null, root, real) catch |err| return cursor.failure.save(err);

    if (@import("collection.zig").outside(relative)) return cursor.failure.save(error.RxSourceOutsideProject);
}

pub fn readPreparedTypeSource(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const cursor = self.cursor;
    const allocator = cursor.allocator;
    const path = self.path;

    const text = Text.read(cursor.io, allocator, path, self.options.texts) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return cursor.failure.save(err);

        try cursor.report(@errorName(err));

        return false;
    };

    if (text.fresh) if (cursor.inputs) |inputs| inputs.record(cursor.io, path, text.bytes) catch |err| return cursor.failure.save(err);

    self.seen.put(allocator, path, {}) catch |err| return cursor.failure.save(err);
    self.result.append(allocator, .{ .path = path, .source = text.bytes }) catch |err| return cursor.failure.save(err);

    return true;
}
