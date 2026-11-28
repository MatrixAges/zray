const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Files = @import("resident/files.zig");
const listing = @import("directory_listing.zig");
const Reader = listing.Reader;
const inputs = compiler.source_inputs;
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

    defer levels.deinit();

    const reader: DirectoryReader = .{
        .root = directory,
        .paths = paths,
        .files = files,
        .prefix = prefix,
        .stat = stat,
        .arenas = arenas,
        .levels = &levels,
    };

    return seedScan(io, allocator, &reader);
}

/// Directory I/O resources for the initial Zig seed.
const DirectoryReader = struct {
    root: std.Io.Dir,
    paths: std.mem.Allocator,
    files: *const Files,
    prefix: []const u8,
    stat: bool,
    arenas: []std.heap.ArenaAllocator,
    levels: *std.heap.ArenaAllocator,
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

pub fn load(io: std.Io, scratch: std.mem.Allocator, files: *Files, root: []const u8, entries: []const Entry, documents: *std.ArrayList(Document)) !void {
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    try documents.ensureUnusedCapacity(scratch, entries.len);

    const target = documents.unusedCapacitySlice()[0..entries.len];

    for (entries, target) |file, *out| {
        const text = file.text orelse try files.read(io, directory, file.relative, file.path, file.retain);

        out.* = .{ .path = file.path, .text = text, .kind = file.kind };
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
    paths: ?std.mem.Allocator,
    stat: bool,
    next: std.atomic.Value(usize) = .init(0),
    fn run(work: *List, participant: usize) void {
        const arena = work.arenas[participant].allocator();

        while (true) {
            const index = work.next.fetchAdd(1, .monotonic);

            if (index >= work.directories.len) return;

            work.listings[index] = work.list(arena, work.directories[index]) catch |err| .{ .failure = err };
        }
    }
    fn list(work: *const List, arena: std.mem.Allocator, parent: []const u8) !Listing {
        var directory = try work.root.openDir(work.io, if (parent.len == 0) "." else parent, .{ .iterate = true });

        defer directory.close(work.io);

        var files: std.ArrayList(Entry) = .empty;
        var directories: std.ArrayList([]const u8) = .empty;
        var entries = Reader.init(directory);
        const base = try inputs.qualify(arena, work.prefix, parent, "");
        const paths = work.paths orelse arena;

        while (try entries.next(work.io)) |entry| switch (entry.kind) {
            .directory => try directories.append(arena, try arena.dupe(u8, entry.name)),
            .file => {
                const route = try inputs.directory.file(paths, base, entry.name, work.prefix.len, std.fs.max_path_bytes) orelse continue;
                const kept = if (route.lookup) work.files else null;
                const text = if (kept) |cache| try cache.unchanged(work.io, directory, entry.name, route.path, entry.metadata) else null;
                const metadata = entry.metadata orelse if (work.stat) Files.metadata(try directory.statFile(work.io, entry.name, .{})) else null;

                try files.append(arena, .{ .path = route.path, .relative = route.relative, .kind = @backingInt(route.kind), .text = text, .metadata = metadata, .retain = route.retain });
            },
            else => {},
        };

        return .{ .files = files.items, .directories = directories.items };
    }
};
