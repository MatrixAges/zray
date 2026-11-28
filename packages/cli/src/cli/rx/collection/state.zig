const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const collection = @import("../collection.zig");
const Text = @import("../../sources/text.zig");
const Collector = @import("../references/collector.zig");
pub const effects = @import("../../sources/effects.zig");
const Error = effects.Error;
const PhysicalResolution = @import("cli_abi").layouts.@"zig:rx_collection_host".PhysicalResolution;
pub const FileRead = @import("cli_abi").layouts.@"zig:rx_collection_host".FileRead;
const rule = @import("cli_source").collect_rx_sources;
const PhysicalState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const RecordState = std.meta.Child(@FieldType(rule.zx_pending, "store_1"));

const StoreHost = struct {
    store_0: *PhysicalState,
    store_1: *RecordState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
        if (pending.store_1) |next| self.store_1.* = next;
    }
};

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
    documents: std.ArrayList(Document) = .empty,
    file: File = undefined,
    physical_view: PhysicalResolution = undefined,
    file_read: FileRead = undefined,
    checked: ?rx.Result = null,
    collector: Collector = undefined,
    pub const Document = union(enum) {
        pending,
        zx: rx.TextSource,
        xml: struct { module: rx.ModuleSource, bytes: []const u8 },
    };
    const File = struct {
        row: usize,
        absolute: []const u8,
        path: []const u8,
        real: []const u8 = undefined,
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
        var store_arena = std.heap.ArenaAllocator.init(backing);

        defer store_arena.deinit();
        defer state.deinit();

        var seen: PhysicalState = &.{ .real_paths = &.{}, .logical_paths = &.{} };
        var records: RecordState = &.{ .functions = &.{}, .modules = &.{}, .stores = &.{}, .gateway = null };
        var host: StoreHost = .{ .store_0 = &seen, .store_1 = &records };

        const selected = rule.execute(&store_arena, &.{
            .collection = @ptrCast(&reference),
            .entry = options.entry,
        }, &host) catch |err| return state.failure.unwrap(err);

        return try state.finish(selected orelse return null);
    }
    fn finish(self: *const State, selected: RecordState) !collection.Data {
        const allocator = self.allocator;
        const documents = self.documents.items;
        const modules = try allocator.alloc(rx.ModuleSource, selected.modules.len);
        const sources = try allocator.alloc(rx.TextSource, selected.modules.len);
        const stores = try allocator.alloc(rx.ModuleSource, selected.stores.len);
        const functions = try allocator.alloc(rx.TextSource, selected.functions.len);

        const gateway: ?collection.GatewaySource = if (selected.gateway) |row| gateway: {
            const document = documents[@intCast(row)].xml.module;

            break :gateway .{ .path = document.path, .node = document.node };
        } else null;

        for (selected.modules, modules, sources) |row, *module, *source| {
            const document = &documents[@intCast(row)].xml;

            module.* = document.module;
            source.* = .{ .path = module.path, .source = document.bytes, .packages = module.packages };
        }

        for (selected.stores, stores) |row, *store| store.* = documents[@intCast(row)].xml.module;
        for (selected.functions, functions) |row, *function| function.* = documents[@intCast(row)].zx;

        return .{ .gateway = gateway, .modules = modules, .stores = stores, .sources = sources, .functions = functions };
    }

    fn deinit(self: *State) void {
        self.releaseDocument();
        self.reference_memory.deinit();
        self.documents.deinit(self.backing);
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
    pub fn fileUnavailable(self: *State, err: anyerror) Error!FileRead {
        if (err == error.OutOfMemory) return self.failure.save(err);

        return .{
            .availability = if (err == error.FileNotFound) .Missing else .Failed,
            .problem = @errorName(err),
        };
    }
};
