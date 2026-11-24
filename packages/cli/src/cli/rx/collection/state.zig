const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const collection = @import("../collection.zig");
const Text = @import("../../sources/text.zig");
const Collector = @import("../references/collector.zig");
pub const effects = @import("../../sources/effects.zig");
const Error = effects.Error;
const abi = @import("cli_abi").native.@"zig:rx_collection_host";
pub const Kind = abi.Kind;
pub const Availability = abi.Availability;
const rule = @import("cli_source").collect_rx_sources;

pub const State = struct {
    result: *collection.Result,
    backing: std.mem.Allocator,
    allocator: std.mem.Allocator,
    options: *const collection.Options,
    project: compiler.project.Options,
    physical_root: []const u8,
    cache: *compiler.project.ParseCache,
    reference_memory: std.heap.ArenaAllocator,
    failure: effects.Failure = .{},
    queue: std.ArrayList([]const u8) = .empty,
    queued: std.StringHashMapUnmanaged(void) = .empty,
    physical: std.StringHashMapUnmanaged([]const u8) = .empty,
    sources: std.ArrayList(rx.TextSource) = .empty,
    functions: std.ArrayList(rx.TextSource) = .empty,
    modules: std.ArrayList(rx.ModuleSource) = .empty,
    stores: std.ArrayList(rx.ModuleSource) = .empty,
    gateway: ?collection.GatewaySource = null,
    file: File = undefined,
    checked: ?rx.Result = null,
    collector: Collector = undefined,
    const File = struct {
        absolute: []const u8,
        path: []const u8,
        real: []const u8 = undefined,
        problem: anyerror = undefined,
        text: Text.Read = undefined,
        documents: ?*Text.Cache = null,
        module: rx.ModuleSource = undefined,
    };
    pub fn load(result: *collection.Result, backing: std.mem.Allocator, options: *const collection.Options) !?collection.Data {
        const allocator = result.arena.allocator();
        const root = try std.fs.path.resolve(allocator, &.{options.root});
        var project = options.project;
        project.root_dir = root;
        const physical_root = try std.Io.Dir.cwd().realPathFileAlloc(options.io, root, allocator);
        var local_cache = compiler.project.ParseCache{ .allocator = allocator };

        defer local_cache.deinit();

        var state: State = .{
            .result = result,
            .backing = backing,
            .allocator = allocator,
            .options = options,
            .project = project,
            .physical_root = physical_root,
            .cache = options.parse_cache orelse &local_cache,
            .reference_memory = .init(backing),
        };

        const reference = &state;

        defer state.deinit();

        const ready = rule.executeIn(allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

        if (!ready) return null;

        return .{ .gateway = state.gateway, .modules = state.modules.items, .stores = state.stores.items, .sources = state.sources.items, .functions = state.functions.items };
    }
    fn deinit(self: *State) void {
        self.releaseDocument();
        self.reference_memory.deinit();
        self.queued.deinit(self.allocator);
    }

    pub fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }

    pub fn releaseDocument(self: *State) void {
        if (self.checked) |*checked| checked.deinit();

        self.checked = null;
    }

    pub fn startCollector(self: *State, scope: ?compiler.project.ImportScope) void {
        const options = self.options;

        self.collector = .{
            .allocator = self.allocator,
            .temporary = &self.reference_memory,
            .options = self.project,
            .owner = self.file.absolute,
            .package_scope = scope,
            .queue = &self.queue,
            .queued = &self.queued,
            .io = options.io,
            .inputs = options.inputs,
            .libraries = options.libraries,
            .writer = options.writer,
        };
    }

    pub fn fileUnavailable(self: *State, err: anyerror) Error!Availability {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.file.problem = err;

        return if (err == error.FileNotFound) .Missing else .Failed;
    }
};

pub fn collectionEntry(handle: *const anyopaque) []const u8 {
    return State.get(handle).options.entry;
}

pub fn registerCollectionEntry(handle: *const anyopaque, kind: Kind) Error!bool {
    const self = State.get(handle);
    const allocator = self.allocator;
    const entry = self.options.entry;

    const first = (switch (kind) {
        .Zx => allocator.dupe(u8, entry),
        .Gateway => rx.normalizeGatewayPath(allocator, entry),
        .Store => rx.normalizeStorePath(allocator, entry),
        .Module => rx.normalizeModulePath(allocator, entry),
    }) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.options.writer.print("{s}: invalid RX entry path\n", .{entry}) catch |failure| return self.failure.save(failure);

        return false;
    };

    self.queue.append(allocator, first) catch |err| return self.failure.save(err);

    const absolute = std.fs.path.resolve(allocator, &.{ self.project.root_dir, first }) catch |err| return self.failure.save(err);

    self.queued.put(allocator, absolute, {}) catch |err| return self.failure.save(err);

    return true;
}

pub fn collectionQueueLength(handle: *const anyopaque) u64 {
    return State.get(handle).queue.items.len;
}

pub fn releaseRxDocument(handle: *const anyopaque) void {
    State.get(handle).releaseDocument();
}
