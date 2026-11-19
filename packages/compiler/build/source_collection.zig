const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Files = @import("resident/files.zig");
const listing = @import("directory_listing.zig");
const Reader = listing.Reader;
const inputs = compiler.source_inputs;
pub const Document = inputs.catalog.Document;

/// Appends the sources and resources under `root`, named with `prefix`; `files`, when given, owns their texts. The tree is
/// listed one depth at a time, every directory of a depth on its own core, and a listed file whose metadata vouches for
/// the text `files` kept takes that text there; the calling thread reads the others afterwards.
pub fn collect(io: std.Io, scratch: std.mem.Allocator, allocator: std.mem.Allocator, files: ?*Files, root: []const u8, prefix: []const u8, documents: *std.ArrayList(Document)) !void {
    const entries = try scan(io, scratch, allocator, files, root, prefix, false);

    try load(io, scratch, allocator, files, root, entries, documents);
}

pub const Entry = struct { relative: []const u8, path: []const u8, metadata: ?Files.Metadata, text: ?[]const u8, kind: inputs.Kind, retain: bool };

/// Lists the input files without reading their contents; `stat` also fills metadata on platforms without bulk stat.
pub fn scan(io: std.Io, allocator: std.mem.Allocator, paths: std.mem.Allocator, files: ?*Files, root: []const u8, prefix: []const u8, stat: bool) ![]const Entry {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    const width = if (stat and listing.bulk_metadata) 1 else @min(compiler.parallel.width(), listers);
    const arenas = try allocator.alloc(std.heap.ArenaAllocator, width);

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    var frontier: [2]std.heap.ArenaAllocator = @splat(.init(std.heap.smp_allocator));
    var results = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    var generation: usize = 0;
    var level: []const []const u8 = &.{""};
    var entries: std.ArrayList(Entry) = .empty;

    defer for (&frontier) |*arena| arena.deinit();
    defer results.deinit();

    while (level.len != 0) {
        const participants = @min(arenas.len, level.len);
        const shared_paths = if (participants == 1) paths else null;
        const listings = try results.allocator().alloc(Listing, level.len);

        var work = List{
            .io = io,
            .root = directory,
            .prefix = prefix,
            .files = files,
            .directories = level,
            .listings = listings,
            .arenas = arenas,
            .paths = shared_paths,
            .stat = stat,
        };

        compiler.parallel.spread(List, &work, List.run, participants);

        for (listings) |found| if (found.failure) |err| return err;

        const next_generation = 1 - generation;
        const schedule = try inputs.directory.schedule(frontier[next_generation].allocator(), level, listings);
        const first = entries.items.len;

        try entries.resize(allocator, first + schedule.files);
        try inputs.directory.flatten(paths, listings, entries.items[first..], prefix.len, shared_paths == null);

        _ = frontier[generation].reset(.retain_capacity);
        _ = results.reset(.retain_capacity);

        for (arenas) |*arena| _ = arena.reset(.retain_capacity);

        generation = next_generation;
        level = schedule.next;
    }

    return entries.items;
}

pub fn load(io: std.Io, scratch: std.mem.Allocator, allocator: std.mem.Allocator, files: ?*Files, root: []const u8, entries: []const Entry, documents: *std.ArrayList(Document)) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    try documents.ensureUnusedCapacity(scratch, entries.len);

    for (entries) |file| {
        const source = file.text orelse if (files) |kept| try kept.read(io, directory, file.relative, file.path, file.retain) else try directory.readFileAlloc(io, file.relative, allocator, .unlimited);

        documents.appendAssumeCapacity(.{ .path = file.path, .text = source, .kind = @backingInt(file.kind) });
    }
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
    files: ?*const Files,
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

                try files.append(arena, .{ .path = route.path, .relative = route.relative, .kind = route.kind, .text = text, .metadata = metadata, .retain = route.retain });
            },
            else => {},
        };

        return .{ .files = files.items, .directories = directories.items };
    }
};
