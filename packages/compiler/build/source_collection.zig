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

    var self: Scan = .{
        .io = io,
        .root = directory,
        .owned = allocator,
        .paths = paths,
        .files = files,
        .prefix = prefix,
        .stat = stat,
        .arenas = arenas,
    };

    defer {
        for (&self.frontier) |*arena| arena.deinit();

        self.results.deinit();
    }

    if (comptime generated) try self.run() else try self.seed();

    return self.entries.items;
}

const DirectoryViews = if (generated) struct {
    names: memory.ReadColumn = undefined,
    files: memory.ListColumn = undefined,
    paths: memory.ListColumn = undefined,
    bytes: []u8 = undefined,
    output_paths: memory.WriteColumn = undefined,
    relatives: memory.WriteColumn = undefined,
} else void;

const Scan = struct {
    io: std.Io,
    root: std.Io.Dir,
    owned: std.mem.Allocator,
    paths: std.mem.Allocator,
    files: *Files,
    prefix: []const u8,
    stat: bool,
    arenas: []std.heap.ArenaAllocator,
    frontier: [2]std.heap.ArenaAllocator = @splat(.init(std.heap.smp_allocator)),
    results: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
    entries: std.ArrayList(Entry) = .empty,
    views: DirectoryViews = undefined,
    scope: if (generated) memory.ArenaScope else void = undefined,
    failure: ?anyerror = null,
    fn prepareLevel(self: *Scan, level: []const []const u8) ![]Listing {
        const participants = @min(self.arenas.len, level.len);
        const listings = try self.results.allocator().alloc(Listing, level.len);

        var work: List = .{
            .io = self.io,
            .root = self.root,
            .prefix = self.prefix,
            .files = self.files,
            .directories = level,
            .listings = listings,
            .arenas = self.arenas,
            .paths = if (participants == 1) self.paths else null,
            .stat = self.stat,
        };

        compiler.parallel.spread(List, &work, List.run, participants);

        for (listings) |found| if (found.failure) |err| return err;

        return listings;
    }
    fn copyPaths(self: *const Scan, level: usize) bool {
        return @min(self.arenas.len, level) != 1;
    }
    fn extend(self: *Scan, count: usize) ![]Entry {
        const first = self.entries.items.len;

        try self.entries.resize(self.owned, first + count);

        return self.entries.items[first..];
    }
    fn retire(self: *Scan, old: usize) void {
        _ = self.frontier[old].reset(.retain_capacity);
        _ = self.results.reset(.retain_capacity);

        for (self.arenas) |*arena| _ = arena.reset(.retain_capacity);
    }
    fn run(self: *Scan) !void {
        const rule = @import("generated_scan_input_directory");
        self.scope = .{ .active = self.paths };

        const views = &self.views;

        rule.executeIn(self.scope.allocator(), &.{
            .scan = @ptrCast(self),
            .directories = @ptrCast(&views.names),
            .files = @ptrCast(&views.files),
            .paths = @ptrCast(&views.paths),
            .target = &.{
                .records = @ptrCast(&views.bytes),
                .paths = @ptrCast(&views.output_paths),
                .relatives = @ptrCast(&views.relatives),
                .width = @sizeOf(Entry),
                .prefix_length = self.prefix.len,
            },
            .initial = &.{""},
        }) catch |err| return self.failure orelse err;
    }
    fn seed(self: *Scan) !void {
        const directory = inputs.directory;
        var frontier: usize = 0;
        var level: []const []const u8 = &.{""};

        while (level.len != 0) {
            const listings = try self.prepareLevel(level);
            const next = 1 - frontier;
            const scheduled = try directory.seedSchedule(self.frontier[next].allocator(), level, listings);
            const target = try self.extend(scheduled.files);

            try directory.seedFlatten(self.paths, listings, target, self.prefix.len, self.copyPaths(level.len));

            self.retire(frontier);

            frontier = next;
            level = scheduled.next;
        }
    }
};

pub fn listGenerationLevel(handle: *anyopaque, level: []const []const u8) Error!bool {
    const self: *Scan = @ptrCast(@alignCast(handle));

    const listings = self.prepareLevel(level) catch |err| {
        self.failure = err;

        return error.GenerationRequestFailed;
    };

    self.views.names = memory.borrowReadColumn([]const []const u8, "directories", listings);
    self.views.files = memory.borrowSliceColumn(&.{"files"}, listings);
    self.views.paths = memory.borrowListColumn([]const u8, "files", "path", listings);

    return self.copyPaths(level.len);
}

pub fn reserveGenerationFiles(handle: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const self: *Scan = @ptrCast(@alignCast(handle));
    const rows = try self.extend(@intCast(count));

    self.views.bytes = std.mem.sliceAsBytes(rows);
    self.views.output_paths = memory.borrowWriteColumn([]const u8, "path", rows);
    self.views.relatives = memory.borrowWriteColumn([]const u8, "relative", rows);
}

pub fn selectGenerationAllocator(handle: *anyopaque, frontier: ?u8) void {
    const self: *Scan = @ptrCast(@alignCast(handle));

    self.scope.active = if (frontier) |index| self.frontier[index].allocator() else self.paths;
}

pub fn retireGenerationLevel(handle: *anyopaque, frontier: u8) void {
    const self: *Scan = @ptrCast(@alignCast(handle));

    self.retire(frontier);
}

const DocumentReader = struct {
    io: std.Io,
    directory: std.Io.Dir,
    files: *Files,
    failure: ?anyerror = null,
    fn read(self: *DocumentReader, relative: []const u8, path: []const u8, retain: bool) ![]const u8 {
        return self.files.read(self.io, self.directory, relative, path, retain);
    }
    fn publish(self: *DocumentReader, scratch: std.mem.Allocator, entries: []const Entry, target: []Document) !void {
        var buffer: [2048]u8 align(@alignOf(u64)) = undefined;
        var backing = std.heap.BufferFirstAllocator.init(&buffer, scratch);
        var arena = std.heap.ArenaAllocator.init(backing.allocator());

        defer arena.deinit();

        const rule = @import("generated_load_input_documents");
        const Input = std.meta.Child(rule.Input);

        const source = memory.borrowReadFields(.{
            .paths = "path",
            .relatives = "relative",
            .texts = "text",
            .kinds = "kind",
            .retained = "retain",
        }, entries);

        const documents = rule.executeIn(arena.allocator(), &.{
            .reader = @ptrCast(self),
            .entries = &source.bind(std.meta.Child(@FieldType(Input, "entries"))),
        }) catch |err| return self.failure orelse err;

        for (documents, target) |doc, *out| {
            out.* = .{ .path = doc.path, .text = doc.text, .kind = doc.kind };
        }
    }
};

pub fn readGenerationDocument(handle: *anyopaque, relative: []const u8, path: []const u8, retain: bool) Error![]const u8 {
    const self: *DocumentReader = @ptrCast(@alignCast(handle));

    return self.read(relative, path, retain) catch |err| {
        self.failure = err;

        return error.GenerationRequestFailed;
    };
}

pub fn load(io: std.Io, scratch: std.mem.Allocator, files: *Files, root: []const u8, entries: []const Entry, documents: *std.ArrayList(Document)) !void {
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    try documents.ensureUnusedCapacity(scratch, entries.len);

    var reader: DocumentReader = .{ .io = io, .directory = directory, .files = files };
    const target = documents.unusedCapacitySlice()[0..entries.len];

    if (comptime generated) {
        try reader.publish(scratch, entries, target);
    } else {
        for (entries, target) |file, *out| {
            const text = file.text orelse try reader.read(file.relative, file.path, file.retain);

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
