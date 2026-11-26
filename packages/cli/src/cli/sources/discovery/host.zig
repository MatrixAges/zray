const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const Traversal = @import("../../sources.zig").Traversal;
const effects = @import("../effects.zig");
const Error = effects.Error;
const Text = @import("../text.zig");
const ResolvedImport = @import("cli_abi").layouts.@"zig:source_loader_host".ResolvedImport;
const ModuleResult = compiler.project.ParseCache.ModuleResult;
const rule = @import("cli_source").discover_sources;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

const State = struct {
    traversal: *Traversal,
    project: compiler.project.Options,
    entry: []const u8,
    recorded: bool,
    failure: effects.Failure = .{},
    owner: ?[]const u8 = null,
    parsed: *const ModuleResult = undefined,
    reference: compiler.project.ModuleReference = undefined,
    path: []const u8 = undefined,
    span: zx.Span = undefined,
    resolved_view: ResolvedImport = undefined,
    fn close(self: *State) void {
        if (self.owner) |owner| self.traversal.allocator.free(owner);

        self.owner = null;
    }
    fn imported(self: *const State, index: usize) zx.syntax.header.Import {
        return switch (self.parsed.*) {
            .native => |*result| (zx.syntax.header.Native{ .program = result.value.parsed.ast }).importAt(index),
            .indexed => |*result| if (compiler.project.ParseCache.indexed_enabled) result.header().importAt(index) else unreachable,
        };
    }
};

pub fn run(traversal: *Traversal, path: []const u8, source: []const u8, recorded: bool) !bool {
    var project = traversal.project;
    project.entry = path;

    var load: State = .{ .traversal = traversal, .project = project, .entry = source, .recorded = recorded };
    const reference = &load;

    defer load.close();

    if (traversal.seen_arena == null) traversal.seen_arena = std.heap.ArenaAllocator.init(traversal.allocator);

    var state_value: std.meta.Child(StoreState) = .{ .paths = traversal.seen_paths, .has_rx = false };
    var state_ptr: StoreState = &state_value;
    var host: StoreHost = .{ .store_0 = &state_ptr };

    rule.execute(&traversal.seen_arena.?, &.{
        .discovery = @ptrCast(&reference),
        .path = path,
    }, &host) catch |err| return load.failure.unwrap(err);

    traversal.seen_paths = state_ptr.paths;

    return state_ptr.has_rx;
}

pub fn registerRoot(handle: *const anyopaque) Error!u64 {
    const self = effects.state(State, handle);
    const traversal = self.traversal;
    const path = self.project.entry;

    if (traversal.inputs) |inputs| inputs.add(traversal.io, path) catch |err| return self.failure.save(err);
    @import("../../../package/source.zig").validateWithInputs(traversal.io, traversal.allocator, path, self.project.package_scopes, traversal.inputs) catch |err| return self.failure.save(err);

    if (!self.recorded) if (traversal.inputs) |inputs| inputs.record(traversal.io, path, self.entry) catch |err| return self.failure.save(err);

    const first = traversal.sources.items.len;

    traversal.append(.{ .path = path, .source = self.entry }) catch |err| return self.failure.save(err);

    return first;
}

pub fn sourceCount(handle: *const anyopaque) u64 {
    return effects.state(State, handle).traversal.sources.items.len;
}

pub fn prepareSource(handle: *const anyopaque, row: u64) Error!void {
    const self = effects.state(State, handle);
    const traversal = self.traversal;
    const item = &traversal.sources.items[@intCast(row)];
    item.* = @import("../templates.zig").prepare(traversal.io, traversal.allocator, item.*, self.project, traversal.inputs) catch |err| return self.failure.save(err);
}

pub fn openHeader(handle: *const anyopaque, row: u64) Error!u64 {
    const self = effects.state(State, handle);
    const traversal = self.traversal;
    const item = &traversal.sources.items[@intCast(row)];
    const owner = std.fs.path.resolve(traversal.allocator, &.{ self.project.root_dir, item.path }) catch |err| return self.failure.save(err);
    self.owner = owner;

    const parsed = traversal.cache.getModule(item.source, owner) catch |err| return self.failure.save(err);

    self.parsed = parsed;

    if (parsed.diagnostic() != null) return 0;

    return switch (parsed.*) {
        .native => |*result| (zx.syntax.header.Native{ .program = result.value.parsed.ast }).importCount(),
        .indexed => |*result| if (compiler.project.ParseCache.indexed_enabled) result.header().importCount() else unreachable,
    };
}

pub fn closeHeader(handle: *const anyopaque) void {
    effects.state(State, handle).close();
}

pub fn resolveImport(handle: *const anyopaque, index: u64) Error!*const ResolvedImport {
    const self = effects.state(State, handle);
    const imported = self.imported(@intCast(index));
    var reporter: zx.Reporter = .{};

    const reference = compiler.project.resolveModuleReference(self.traversal.allocator, self.owner.?, imported.path, self.project, &reporter, imported.span) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        self.resolved_view = .{ .target = .Deferred, .path = "" };

        return &self.resolved_view;
    };

    self.reference = reference;
    self.span = imported.span;

    switch (reference.target) {
        .compiled => {
            self.resolved_view = .{ .target = .Compiled, .path = "" };
        },
        .source => |path| {
            self.path = path;
            self.resolved_view = .{ .target = .Source, .path = path };
        },
    }

    return &self.resolved_view;
}

pub fn admitCompiledImport(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const traversal = self.traversal;
    const libraries = traversal.libraries orelse return self.failure.save(error.CompiledLibraryLoaderRequired);

    _ = libraries.add(traversal.io, self.reference.target.compiled, self.project, traversal.inputs) catch |err| return self.failure.save(err);
}

pub fn selectImportFile(handle: *const anyopaque) Error!?[]const u8 {
    const self = effects.state(State, handle);
    const traversal = self.traversal;

    if (self.reference.file) {
        const path = @import("../module_path.zig").select(traversal.io, traversal.allocator, self.path, traversal.inputs) catch |err| return self.failure.save(err);
        var reporter: zx.Reporter = .{};

        compiler.project.checkFileTarget(self.owner.?, path, self.project, &reporter, self.span) catch |err| {
            if (err == error.OutOfMemory) return self.failure.save(err);

            return null;
        };

        self.path = path;
    }

    return self.path;
}

pub fn loadImportText(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = effects.state(State, handle);
    const traversal = self.traversal;
    const io = traversal.io;
    const allocator = traversal.allocator;
    const inputs = traversal.inputs;

    if (inputs) |observed| observed.add(io, path) catch |err| return self.failure.save(err);

    @import("../../../package/source.zig").validateWithInputs(io, allocator, path, self.project.package_scopes, inputs) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return self.failure.save(err),
    };

    const text: Text.Read = if (if (traversal.known) |known| known.get(path) else null) |bytes|
        .{ .bytes = bytes, .fresh = false }

    else
        Text.read(io, allocator, path, traversal.texts) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return self.failure.save(err),
        };

    if (text.fresh) if (inputs) |observed| observed.record(io, path, text.bytes) catch |err| return self.failure.save(err);

    traversal.append(.{ .path = path, .source = text.bytes }) catch |err| return self.failure.save(err);

    return true;
}
