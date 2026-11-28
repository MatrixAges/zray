const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Files = @import("resident/files.zig");
const listing = @import("directory_listing.zig");
const Reader = listing.Reader;
const inputs = compiler.source_inputs;
const generated = compiler.input_generation.generated;
const memory = if (generated) @import("zx").memory else void;
const Error = error{GenerationRequestFailed};
pub const Document = inputs.catalog.Document;
pub const Entry = struct { relative: []const u8, path: []const u8, metadata: ?Files.Metadata, text: ?[]const u8, kind: u8, retain: bool };

pub fn collect(io: std.Io, scratch: std.mem.Allocator, allocator: std.mem.Allocator, files: *Files, root: []const u8, prefix: []const u8, documents: *std.ArrayList(Document)) !void {
    try load(io, scratch, files, root, try scan(io, scratch, allocator, files, root, prefix, false), documents);
}

/// Lists the input files without reading their contents; `stat` also fills metadata on platforms without bulk stat.
pub fn scan(io: std.Io, allocator: std.mem.Allocator, paths: std.mem.Allocator, files: *Files, root: []const u8, prefix: []const u8, stat: bool) ![]const Entry {
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    const width = if (stat and listing.bulk_metadata) 1 else @min(compiler.parallel.width(), listers);
    const arenas = try allocator.alloc(std.heap.ArenaAllocator, width);

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    var levels = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    var failure: ?anyerror = null;
    var retained: [listers]std.heap.ArenaAllocator = @splat(.init(std.heap.smp_allocator));

    defer {
        levels.deinit();

        if (comptime generated) for (retained[0..width]) |*arena| arena.deinit();
    }

    const reader: DirectoryReader = .{
        .root = directory,
        .paths = paths,
        .files = files,
        .prefix = prefix,
        .stat = stat,
        .arenas = arenas,
        .retained = retained[0..width],
        .levels = &levels,
        .failure = &failure,
    };

    if (comptime !generated) return seedScan(io, allocator, &reader);

    const rule = @import("generated_scan_input_directory");

    const input: std.meta.Child(rule.Input) = .{
        .reader = @ptrCast(&reader),
        .width = @sizeOf(Entry),
        .workers = width,
        .initial = &.{""},
    };

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const Entries = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
    const initial: std.meta.Child(Entries) = .{ .batches = &.{}, .count = 0 };
    var collected: Entries = &initial;

    var stores = struct {
        store_0: *Entries,
        pub fn commit(self: *@This(), pending: rule.zx_pending) error{}!void {
            if (pending.store_0) |next| self.store_0.* = next;
        }
    }{ .store_0 = &collected };

    const result = rule.executeIn(scratch.allocator(), &input, &stores, io) catch |err| return failure orelse err;
    const entries = try allocator.alloc(Entry, @intCast(result.count));
    var offset: usize = 0;

    for (result.batches) |batch| {
        for (batch.records) |chunk| {
            const count = chunk.len / @sizeOf(Entry);
            const rows = entries[offset..][0..count];

            @memcpy(std.mem.sliceAsBytes(rows), chunk);

            if (batch.copy_paths) for (rows) |*row| {
                row.path = try paths.dupe(u8, row.path);
                row.relative = row.path[prefix.len..];
            };

            offset += count;
        }
    }

    return entries;
}

/// Borrows directory I/O resources. RX keeps the frontier and the completed batches.
/// The worker arenas back the file records until scan publishes the final slice.
const DirectoryReader = struct {
    root: std.Io.Dir,
    paths: std.mem.Allocator,
    files: *const Files,
    prefix: []const u8,
    stat: bool,
    arenas: []std.heap.ArenaAllocator,
    retained: []std.heap.ArenaAllocator,
    levels: *std.heap.ArenaAllocator,
    failure: *?anyerror,
    fn read(self: *const DirectoryReader, io: std.Io, parents: []const []const u8, copy_paths: bool) ![]const Listing {
        _ = self.levels.reset(.retain_capacity);

        for (self.arenas) |*arena| _ = arena.reset(.retain_capacity);

        const listings = try self.levels.allocator().alloc(Listing, parents.len);
        const participants = @min(self.arenas.len, parents.len);

        var work: List = .{
            .io = io,
            .root = self.root,
            .prefix = self.prefix,
            .files = self.files,
            .directories = parents,
            .listings = listings,
            .arenas = self.arenas,
            .retained = self.retained,
            .paths = if (copy_paths) null else self.paths,
            .stat = self.stat,
        };

        compiler.parallel.spread(List, &work, List.run, participants);

        for (listings) |found| if (found.failure) |err| return err;

        return listings;
    }
};

fn seedScan(io: std.Io, allocator: std.mem.Allocator, reader: *const DirectoryReader) ![]const Entry {
    const directory = inputs.directory;
    var frontier: [2]std.heap.ArenaAllocator = @splat(.init(std.heap.smp_allocator));
    var active: usize = 0;
    var parents: []const []const u8 = &.{""};
    var entries: std.ArrayList(Entry) = .empty;

    defer for (&frontier) |*arena| arena.deinit();

    while (parents.len != 0) {
        const copy_paths = @min(reader.arenas.len, parents.len) != 1;
        const listings = try reader.read(io, parents, copy_paths);
        const next = 1 - active;
        const scheduled = try directory.seedSchedule(frontier[next].allocator(), parents, listings);
        const first = entries.items.len;

        try entries.resize(allocator, first + scheduled.files);
        try directory.seedFlatten(reader.paths, listings, entries.items[first..], reader.prefix.len, copy_paths);

        _ = frontier[active].reset(.retain_capacity);
        active = next;
        parents = scheduled.next;
    }

    return entries.items;
}

const Host = if (generated) @import("generation_execution_abi").native.@"zig:generation_host" else void;

pub fn listGenerationLevel(allocator: std.mem.Allocator, io: std.Io, reference: *const anyopaque, parents: []const []const u8, copy_paths: bool) (Error || error{OutOfMemory})!Host.DirectoryListing {
    const reader: *const DirectoryReader = @ptrCast(@alignCast(reference));

    const listings = reader.read(io, parents, copy_paths) catch |err| {
        reader.failure.* = err;

        return error.GenerationRequestFailed;
    };

    const names = try reader.levels.allocator().alloc([]const []const u8, listings.len);
    const files = try allocator.alloc([]const u8, listings.len);

    for (listings, names, files) |found, *directory_names, *records| {
        directory_names.* = found.directories;
        records.* = std.mem.sliceAsBytes(found.files);
    }

    const level = try allocator.create(std.meta.Child(Host.DirectoryListing));

    level.* = .{ .directories = names, .files = files };

    return level;
}

fn loadDocuments(io: std.Io, scratch: std.mem.Allocator, files: *Files, directory: std.Io.Dir, entries: []const Entry, target: []Document) !void {
    var buffer: [2048]u8 align(@alignOf(u64)) = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, scratch);
    var arena = std.heap.ArenaAllocator.init(backing.allocator());

    defer arena.deinit();

    const rule = @import("generated_load_input_documents");

    const source = memory.borrowReadFields(.{
        .paths = "path",
        .texts = "text",
        .relatives = "relative",
        .retained = "retain",
        .kinds = "kind",
    }, entries);

    const documents = try rule.executeIn(arena.allocator(), &source.bind(std.meta.Child(rule.Input)));

    for (documents, target) |doc, *out| {
        const text = if (doc.read) |read| try files.read(io, directory, read.relative, doc.path, read.retain) else doc.text;

        out.* = .{ .path = doc.path, .text = text, .kind = doc.kind };
    }
}

pub fn load(io: std.Io, scratch: std.mem.Allocator, files: *Files, root: []const u8, entries: []const Entry, documents: *std.ArrayList(Document)) !void {
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    try documents.ensureUnusedCapacity(scratch, entries.len);

    const target = documents.unusedCapacitySlice()[0..entries.len];

    if (comptime generated) {
        try loadDocuments(io, scratch, files, directory, entries, target);
    } else {
        for (entries, target) |file, *out| {
            const text = file.text orelse try files.read(io, directory, file.relative, file.path, file.retain);

            out.* = .{ .path = file.path, .text = text, .kind = file.kind };
        }
    }

    documents.items.len += target.len;
}

pub const Catalog = struct {
    sources: []const compiler.project.Source,
    modules: []const rx.TextSource,
    templates: []const compiler.project.Resource,
};

pub fn publish(workspace: std.mem.Allocator, allocator: std.mem.Allocator, documents: []const Document, packages: []const compiler.project.Package, attach_templates: bool) !Catalog {
    const plan = try inputs.catalog.prepare(workspace, documents);
    const sources = try allocator.alloc(compiler.project.Source, plan.sources);
    const modules = try allocator.alloc(rx.TextSource, plan.modules);
    const templates = try allocator.alloc(compiler.project.Resource, documents.len - plan.sources - plan.modules);

    try inputs.catalog.publish(documents, plan, .{ .sources = sources, .modules = modules, .templates = templates }, packages, attach_templates);

    return .{ .sources = sources, .modules = modules, .templates = templates };
}

/// Threads listing at once; the file system serves more of them no faster, as they wait on its locks.
const listers = 8;
const Listing = struct { files: []const Entry = &.{}, directories: []const []const u8 = &.{}, failure: ?anyerror = null };

/// The directories of one depth, listed by every participant taking the next one left.
const List = struct {
    io: std.Io,
    root: std.Io.Dir,
    prefix: []const u8,
    files: *const Files,
    directories: []const []const u8,
    listings: []Listing,
    arenas: []std.heap.ArenaAllocator,
    retained: []std.heap.ArenaAllocator,
    paths: ?std.mem.Allocator,
    stat: bool,
    next: std.atomic.Value(usize) = .init(0),
    fn run(work: *List, participant: usize) void {
        const arena = work.arenas[participant].allocator();
        const output = if (comptime generated) work.retained[participant].allocator() else arena;

        while (true) {
            const index = work.next.fetchAdd(1, .monotonic);

            if (index >= work.directories.len) return;

            work.listings[index] = work.list(arena, output, work.directories[index]) catch |err| .{ .failure = err };
        }
    }
    fn list(work: *const List, arena: std.mem.Allocator, output: std.mem.Allocator, parent: []const u8) !Listing {
        var directory = try work.root.openDir(work.io, if (parent.len == 0) "." else parent, .{ .iterate = true });

        defer directory.close(work.io);

        var files: std.ArrayList(Entry) = .empty;
        var directories: std.ArrayList([]const u8) = .empty;
        var entries = Reader.init(directory);
        const base = try inputs.qualify(arena, work.prefix, parent, "");
        const paths = work.paths orelse output;

        while (try entries.next(work.io)) |entry| switch (entry.kind) {
            .directory => try directories.append(arena, try arena.dupe(u8, entry.name)),
            .file => {
                const route = try inputs.directory.file(paths, base, entry.name, work.prefix.len, std.fs.max_path_bytes) orelse continue;
                const kept = if (route.lookup) work.files else null;
                const text = if (kept) |cache| try cache.unchanged(work.io, directory, entry.name, route.path, entry.metadata) else null;
                const metadata = entry.metadata orelse if (work.stat) Files.metadata(try directory.statFile(work.io, entry.name, .{})) else null;

                try files.append(output, .{ .path = route.path, .relative = route.relative, .kind = @backingInt(route.kind), .text = text, .metadata = metadata, .retain = route.retain });
            },
            else => {},
        };

        return .{ .files = files.items, .directories = directories.items };
    }
};
