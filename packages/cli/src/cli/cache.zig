const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const SemanticCache = compiler.project.SemanticCache;
const identity = @import("cache_identity").digest;
const Self = @This();
const Effects = @import("sources/effects.zig");
const Error = Effects.Error;
const Kind = enum { source, native };

io: std.Io,
allocator: std.mem.Allocator,
directory: []const u8,
buffer: std.Io.Writer.Allocating,
loaded: usize = 0,
discarded: usize = 0,
written: usize = 0,
native_loaded: usize = 0,
native_written: usize = 0,
pub fn init(io: std.Io, allocator: std.mem.Allocator, backing: std.mem.Allocator, root: []const u8) !Self {
    const directory = try std.fs.path.join(allocator, &.{ root, ".zxc", "cache", "semantic", &std.fmt.bytesToHex(identity(), .lower) });

    return .{ .io = io, .allocator = allocator, .directory = directory, .buffer = .init(backing) };
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
    self.allocator.free(self.directory);

    self.* = undefined;
}

const Read = struct {
    disk: *Self,
    sources: []const compiler.project.Source,
    project: *const compiler.project.Options,
    cache: *SemanticCache,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    failure: Effects.Failure = .{},
    fn get(handle: *const anyopaque) *Read {
        return Effects.state(Read, handle);
    }
};

pub fn load(self: *Self, sources: []const compiler.project.Source, project: compiler.project.Options, cache: *SemanticCache) !void {
    var state: Read = .{ .disk = self, .sources = sources, .project = &project, .cache = cache };
    const reference = &state;

    defer state.seen.deinit(self.allocator);
    @import("cli_source").load_disk_semantic_cache.executeIn(self.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);
}

pub fn diskSemanticSourceCount(handle: *const anyopaque) u64 {
    return Read.get(handle).sources.len;
}

pub fn loadDiskSemanticSource(handle: *const anyopaque, index: u64) Error!void {
    const self = Read.get(handle);
    const disk = self.disk;
    const cache = self.cache;
    const source = &self.sources[@intCast(index)];
    const path = std.fs.path.resolve(disk.allocator, &.{ self.project.root_dir, source.path }) catch |err| return self.failure.save(err);

    defer disk.allocator.free(path);

    if (disk.loadEntry(cache.allocator, &cache.entries, path, .source) catch |err| return self.failure.save(err)) disk.loaded += 1;

    const parsed = cache.parse_cache.getModule(source.source, path) catch |err| return self.failure.save(err);

    if (parsed.diagnostic() != null) return;

    const imports: ImportLoader = .{ .disk = disk, .cache = cache, .seen = &self.seen };

    switch (parsed.*) {
        .native => |result| SemanticCache.prefetch(zx.syntax.header.Native{ .program = result.value.parsed.ast }, path, self.project, imports) catch |err| return self.failure.save(err),
        .indexed => |*result| if (compiler.project.ParseCache.indexed_enabled) SemanticCache.prefetch(result.header(), path, self.project, imports) catch |err| return self.failure.save(err) else unreachable,
    }
}

const ImportLoader = struct {
    disk: *Self,
    cache: *SemanticCache,
    seen: *std.StringHashMapUnmanaged(void),
    pub fn loadNative(self: @This(), key: []const u8) !void {
        const found = try self.seen.getOrPut(self.disk.allocator, key);

        if (found.found_existing) return;
        if (try self.disk.loadEntry(self.cache.allocator, &self.cache.native.items, key, .native)) self.disk.native_loaded += 1;
    }
};

fn loadEntry(self: *Self, allocator: std.mem.Allocator, entries: *SemanticCache.entry_store.Map, key: []const u8, kind: Kind) !bool {
    const location = try self.filePath(key, kind);

    defer self.allocator.free(location);

    const bytes = @import("cache/buffer.zig").read(&self.buffer, self.io, location, SemanticCache.maximum_file_size) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.StreamTooLong => {
            self.discarded += 1;

            return false;
        },
        else => return err,
    };

    SemanticCache.entry_store.load(allocator, entries, bytes, identity(), key) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        self.discarded += 1;

        return false;
    };

    return true;
}

const Write = struct {
    disk: *Self,
    cache: *SemanticCache,
    entries: *SemanticCache.entry_store.Map = undefined,
    kind: Kind = undefined,
    failure: Effects.Failure = .{},
    fn get(handle: *const anyopaque) *Write {
        return Effects.state(Write, handle);
    }
    fn select(self: *Write, kind: Kind) usize {
        self.kind = kind;
        self.entries = if (kind == .native) &self.cache.native.items else &self.cache.entries;

        return self.entries.keys.items.len;
    }
};

pub fn save(self: *Self, cache: *SemanticCache) !void {
    var state: Write = .{ .disk = self, .cache = cache };
    const reference = &state;

    @import("cli_source").save_disk_semantic_cache.executeIn(self.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);
}

pub fn selectDiskSemanticSources(handle: *const anyopaque) u64 {
    return Write.get(handle).select(.source);
}

pub fn selectDiskSemanticNatives(handle: *const anyopaque) u64 {
    return Write.get(handle).select(.native);
}

pub fn diskSemanticDirty(handle: *const anyopaque, index: u64) bool {
    return Write.get(handle).entries.values.items[@intCast(index)].dirty;
}

pub fn saveDiskSemanticEntry(handle: *const anyopaque, index: u64) Error!void {
    const self = Write.get(handle);
    const disk = self.disk;
    const row: usize = @intCast(index);
    const key = self.entries.keys.items[row];
    const entry = self.entries.values.items[row];
    const location = disk.filePath(key, self.kind) catch |err| return self.failure.save(err);

    defer disk.allocator.free(location);
    SemanticCache.codec.encodeInto(&disk.buffer, entry.result.value, entry.context_digest, identity()) catch |err| return self.failure.save(err);

    const bytes = disk.buffer.writer.buffered();

    if (bytes.len >= SemanticCache.maximum_file_size) return;

    @import("artifacts.zig").write(disk.io, location, bytes) catch |err| return self.failure.save(err);

    entry.dirty = false;

    if (self.kind == .native) disk.native_written += 1 else disk.written += 1;
}

pub fn report(self: *const Self, cache: *const SemanticCache, writer: *std.Io.Writer) !void {
    try writer.print("zxc cache: analyzed={d} reused={d} loaded={d} written={d} discarded={d} uncacheable={d} native_analyzed={d} native_reused={d} native_loaded={d} native_written={d}\n", .{ cache.analyzed, cache.reused, self.loaded, self.written, self.discarded, cache.uncacheable, cache.native.analyzed, cache.native.reused, self.native_loaded, self.native_written });
}

fn filePath(self: *const Self, source: []const u8, kind: Kind) std.mem.Allocator.Error![]u8 {
    return SemanticCache.filePath(self.allocator, self.directory, source, kind == .native);
}
