const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Files = @import("resident/files.zig");
const listing = @import("directory_listing.zig");
const Reader = listing.Reader;
const inputs = compiler.source_inputs;

pub fn sortPaths(comptime Row: type, rows: []Row) void {
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
}

/// Appends the sources and resources under `root`, named with `prefix`; `files`, when given, owns their texts. The tree is
/// listed one depth at a time, every directory of a depth on its own core, and a listed file whose metadata vouches for
/// the text `files` kept takes that text there; the calling thread reads the others afterwards.
pub fn collect(io: std.Io, scratch: std.mem.Allocator, allocator: std.mem.Allocator, files: ?*Files, root: []const u8, prefix: []const u8, sources: *std.ArrayList(compiler.project.Source), modules: *std.ArrayList(rx.TextSource), templates: *std.ArrayList(compiler.project.Resource)) !void {
    try load(io, allocator, files, root, try scan(io, scratch, allocator, files, root, prefix, false), sources, modules, templates);
}

pub const Entry = struct { relative: []const u8, path: []const u8, metadata: ?Files.Metadata, text: ?[]const u8, kind: inputs.Kind };

/// Lists the input files without reading their contents; `stat` also fills metadata on platforms without bulk stat.
pub fn scan(io: std.Io, allocator: std.mem.Allocator, paths: std.mem.Allocator, files: ?*Files, root: []const u8, prefix: []const u8, stat: bool) ![]const Entry {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    const width = if (stat and listing.bulk_metadata) 1 else @min(compiler.parallel.width(), listers);
    const arenas = try allocator.alloc(std.heap.ArenaAllocator, width);

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    var level: std.ArrayList([]const u8) = .empty;
    var entries: std.ArrayList(Entry) = .empty;

    try level.append(allocator, "");

    while (level.items.len != 0) {
        var work = List{ .io = io, .root = directory, .prefix = prefix, .files = files, .directories = level.items, .listings = try allocator.alloc(anyerror!Listing, level.items.len), .arenas = arenas, .stat = stat };

        compiler.parallel.spread(List, &work, List.run, @min(arenas.len, level.items.len));

        var next: std.ArrayList([]const u8) = .empty;

        for (level.items, work.listings) |parent, result| {
            const found = try result;

            for (found.directories) |name| try next.append(allocator, try inputs.qualify(allocator, "", parent, name));

            for (found.files) |file| {
                const path = try inputs.qualify(paths, prefix, parent, file.name);

                try entries.append(allocator, .{ .relative = path[prefix.len..], .path = path, .text = file.text, .metadata = file.metadata, .kind = file.kind });
            }
        }

        level = next;
    }

    return entries.items;
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, files: ?*Files, root: []const u8, entries: []const Entry, sources: *std.ArrayList(compiler.project.Source), modules: *std.ArrayList(rx.TextSource), templates: *std.ArrayList(compiler.project.Resource)) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});

    defer directory.close(io);

    for (entries) |file| {
        // The XML parser owns its source. ZX, template and native interface analyses may borrow theirs.
        const source = file.text orelse if (files) |kept| try kept.read(io, directory, file.relative, file.path, file.kind != .RX) else try directory.readFileAlloc(io, file.relative, allocator, .unlimited);

        switch (file.kind) {
            .ZX => try sources.append(allocator, .{ .path = file.path, .source = source }),
            .RX => try modules.append(allocator, .{ .path = file.path, .source = source }),
            .Template => try templates.append(allocator, .{ .path = file.path, .source = source }),
            .Ignored => unreachable,
        }
    }
}

/// Threads listing at once; the file system serves more of them no faster, as they wait on its locks.
const listers = 8;
const File = struct { name: []const u8, kind: inputs.Kind, text: ?[]const u8, metadata: ?Files.Metadata };
const Listing = struct { files: []const File, directories: []const []const u8 };

/// The directories of one depth, listed by every participant taking the next one left.
const List = struct {
    io: std.Io,
    root: std.Io.Dir,
    prefix: []const u8,
    files: ?*const Files,
    directories: []const []const u8,
    listings: []anyerror!Listing,
    arenas: []std.heap.ArenaAllocator,
    stat: bool,
    next: std.atomic.Value(usize) = .init(0),
    fn run(work: *List, participant: usize) void {
        const arena = work.arenas[participant].allocator();

        while (true) {
            const index = work.next.fetchAdd(1, .monotonic);

            if (index >= work.directories.len) return;

            work.listings[index] = work.list(arena, work.directories[index]);
        }
    }
    fn list(work: *const List, arena: std.mem.Allocator, parent: []const u8) !Listing {
        var directory = try work.root.openDir(work.io, if (parent.len == 0) "." else parent, .{ .iterate = true });

        defer directory.close(work.io);

        var files: std.ArrayList(File) = .empty;
        var directories: std.ArrayList([]const u8) = .empty;
        var entries = Reader.init(directory);

        while (try entries.next(work.io)) |entry| switch (entry.kind) {
            .directory => try directories.append(arena, try arena.dupe(u8, entry.name)),
            .file => {
                const kind = inputs.kind(entry.name);

                if (kind == .Ignored) continue;
                try files.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = kind, .text = try work.kept(directory, parent, entry), .metadata = entry.metadata orelse if (work.stat) Files.metadata(try directory.statFile(work.io, entry.name, .{})) else null });
            },
            else => {},
        };

        return .{ .files = files.items, .directories = directories.items };
    }

    /// The text `files` kept for `entry` of `parent`, if its metadata still vouches for it.
    fn kept(work: *const List, directory: std.Io.Dir, parent: []const u8, entry: listing.Entry) !?[]const u8 {
        const files = work.files orelse return null;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);
        const key = inputs.qualify(scratch.allocator(), work.prefix, parent, entry.name) catch return null;

        return files.unchanged(work.io, directory, entry.name, key, entry.metadata);
    }
};
