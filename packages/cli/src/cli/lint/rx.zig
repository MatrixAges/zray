const std = @import("std");
const rx = @import("rx");
const Compile = @import("../compile.zig");
const Loaded = @import("../project.zig").Loaded;
const sources = @import("sources.zig");
const collection = @import("../rx/collection.zig");
const gateway = @import("../rx/gateway/analyze.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    loaded: *const Loaded,
    collection: ?collection.Result = null,
    functions: []const rx.TextSource = &.{},
    gateway: ?gateway.Result = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.gateway) |*analyzed| analyzed.deinit();
        if (self.collection) |*loaded| loaded.deinit();
    }
};

pub fn run(context: Compile.Context, loaded: *const Loaded, store: bool) !Compile.Status {
    var state: State = .{ .context = &context, .loaded = loaded };
    const reference = &state;
    const rule = @import("cli_source").lint_special_rx;

    defer state.deinit();

    const valid = rule.executeIn(context.allocator, &.{ .check = @ptrCast(&reference), .store = store }) catch |err| return state.failure.unwrap(err);

    return if (valid) .success else .failed;
}

pub fn checkSpecialSource(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = sources.file(self.context.*, self.loaded.project.entry) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn collectLintStore(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const path = self.loaded.project.entry;
    const root = std.fs.path.resolve(context.allocator, &.{self.loaded.project.root_dir}) catch |err| return self.failure.save(err);
    const entry = std.fs.path.relative(context.allocator, root, null, root, path) catch |err| return self.failure.save(err);

    self.collection = collection.load(context.allocator, .{
        .io = context.io,
        .root = root,
        .entry = entry,
        .writer = context.stderr,
        .project = self.loaded.project,
    }) catch |err| return self.failure.save(err);

    return self.collection != null;
}

pub fn collectLintStoreTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const loaded = &self.collection.?.data;

    self.functions = (@import("../rx/type_sources.zig").collect(context.allocator, .{
        .io = context.io,
        .project = self.loaded.project,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .functions = loaded.functions,
        .writer = context.stderr,
    }) catch |err| return self.failure.save(err)) orelse return false;

    return true;
}

pub fn checkLintStoreTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return @import("../rx/store_types.zig").validate(context.io, context.allocator, self.collection.?.data, self.functions, self.loaded.project, context.stderr) catch |err| self.failure.save(err);
}

pub fn analyzeLintGateway(handle: *const anyopaque) Error!?bool {
    const self = State.get(handle);
    const context = self.context;

    self.gateway = gateway.run(context.allocator, .{
        .io = context.io,
        .loaded = self.loaded.*,
        .writer = context.stderr,
    }) catch |err| return self.failure.save(err);

    const analyzed = &(self.gateway orelse return null);

    return analyzed.services != null;
}

pub fn checkLintServices(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = sources.check(self.context.*, self.gateway.?.services.?.modules, self.loaded.project.root_dir) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn linkLintGateway(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    var linked = self.gateway.?.link(self.context.allocator) catch |err| return self.failure.save(err);

    if (linked) |*library| library.deinit();
}
