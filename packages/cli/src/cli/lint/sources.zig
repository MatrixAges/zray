const std = @import("std");
const Compile = @import("../compile.zig");
const Module = @import("../library/analyze.zig").Module;
const Source = @import("compiler").project.Source;
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    modules: []const Module,
    root: []const u8,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    module: *const Module = undefined,
    source: *const Source = undefined,
    path: []const u8 = undefined,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn admit(self: *State, path: []const u8) Error!bool {
        const row = self.seen.getOrPut(self.context.allocator, path) catch |err| return self.failure.save(err);

        return !row.found_existing;
    }
};

pub fn check(context: Compile.Context, modules: []const Module, root: []const u8) !Compile.Status {
    var state: State = .{ .context = &context, .modules = modules, .root = root };
    const reference = &state;

    defer state.seen.deinit(context.allocator);

    const valid = @import("cli_source").lint_reachable.executeIn(context.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return if (valid) .success else .failed;
}

pub fn reachableLintModuleCount(handle: *const anyopaque) u64 {
    return State.get(handle).modules.len;
}

pub fn selectReachableLintModule(handle: *const anyopaque, index: u64) u64 {
    const self = State.get(handle);

    self.module = &self.modules[@intCast(index)];

    return self.module.sources.len;
}

pub fn admitReachableLintSource(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);

    self.source = &self.module.sources[@intCast(index)];

    return self.admit(self.source.path);
}

pub fn checkReachableLintSource(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    var selected = self.context.*;
    selected.options.input = self.source.path;
    const status = @import("../lint.zig").checkSource(selected, self.source.source) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn reachableLintStoreCount(handle: *const anyopaque) u64 {
    return State.get(handle).module.store_definitions.len;
}

pub fn admitReachableLintStore(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const definition = &self.module.store_definitions[@intCast(index)];

    self.path = std.fs.path.resolve(self.context.allocator, &.{ self.root, definition.source_path }) catch |err| return self.failure.save(err);

    return self.admit(self.path);
}

pub fn checkReachableLintStore(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = file(self.context.*, self.path) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn file(context: Compile.Context, path: []const u8) !Compile.Status {
    var selected = context;
    selected.options.input = path;
    const source = try std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024));

    defer context.allocator.free(source);

    return @import("../lint.zig").checkSource(selected, source);
}
