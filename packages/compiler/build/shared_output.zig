const std = @import("std");
const compiler = @import("compiler");
const layout = @import("partition/layout.zig");
const parallel = @import("parallel.zig");
const ledger = compiler.zig.file_ledger;

/// Writes the generated tree. With `partitions` set, function files are spread over that many separately
/// compiled partitions. Only changed files are rewritten and files no longer generated are removed, so an
/// output directory reused across runs keeps unchanged files byte- and timestamp-stable for Zig's cache.
pub fn write(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, output: []const u8, bundle: compiler.zig.LibraryBundle, partitions: u32) !void {
    const groups = try ledger.inventory.group(allocator, bundle.modules);
    const tree = try ledger.assembly.prepare(allocator, &bundle, groups, partitions != 0);
    const slots = tree.sections;
    const head = tree.files;

    for (bundle.public_modules, head[slots.adapters..slots.support]) |module, *file| {
        file.source = try compiler.zig.host.bootstrapReexports(allocator, workspace, .{
            .member = module.name,
            .value_entry = module.value_entry,
            .state_entry = module.state_entry,
            .allocator_entry = module.allocator_entry,
            .constant_only = module.constant_only,
        });
    }

    const functions: []const layout.File = if (partitions == 0) blk: {
        head[slots.root].source = try compiler.zig.partition.rootBacked(allocator, workspace, tree.modules, false);

        break :blk groups.functions;
    } else blk: {
        var scratch = std.heap.ArenaAllocator.init(workspace);

        defer scratch.deinit();

        const original = try ledger.inventory.originals(allocator, scratch.allocator(), groups.functions, head[slots.originals..slots.original_root]);
        head[slots.original_root].source = try compiler.zig.partition.indexedRoot(allocator, workspace, original, null);
        head[slots.root].source = try compiler.zig.partition.rootBacked(allocator, workspace, tree.modules, true);

        break :blk try layout.plan(io, allocator, workspace, groups.functions, original, head[slots.support..slots.signatures], partitions);
    };

    try mirror(io, allocator, workspace, output, .{ .head = head, .functions = functions });
}

const file_manifest = @import("partition/file_manifest.zig");
const manifest_name = file_manifest.name;

/// Records the content hash of every written file in a manifest, so a later run compares hashes instead of
/// reading files back, and removes exactly the files the previous run wrote and this one does not. Without a
/// manifest the directory is walked once and every file not generated now is removed.
fn mirror(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, output: []const u8, files: Files) !void {
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, output);

    var directory = try cwd.openDir(io, output, .{ .iterate = true });

    defer directory.close(io);

    const previous = try recorded(io, allocator, directory);
    var manifest: std.Io.Writer.Allocating = .init(allocator);

    try remove(io, directory, manifest_name);

    const count = files.len();
    const arenas = try parallel.Arenas.init(io, allocator, count);

    defer arenas.deinit();

    const paths = try allocator.alloc([]const u8, count);
    const hashing = Hashing{ .files = files, .paths = paths, .hashes = try allocator.alloc(u64, count) };

    try parallel.each(arenas, blocks(files.head) + blocks(files.functions), &hashing);
    try manifest.writer.ensureUnusedCapacity(count * 64);

    var selected = try ledger.changes(workspace, .{
        .paths = paths,
        .hashes = hashing.hashes,
        .previous_paths = if (previous) |known| known.paths else &.{},
        .previous_hashes = if (previous) |known| known.hashes else &.{},
        .present = previous != null,
    });

    defer selected.deinit();

    const changed = selected.value.changed;

    try file_manifest.write(ledger.manifest_write, &manifest.writer, paths, hashing.hashes);

    if (changed.len != 0) {
        var temporary = std.heap.ArenaAllocator.init(workspace);

        defer temporary.deinit();

        const parents = try ledger.parents(temporary.allocator(), paths, changed);

        for (parents) |parent| try directory.createDirPath(io, parent);
    }

    try parallel.each(arenas, changed.len, &Writing{ .io = io, .directory = directory, .files = files, .changed = changed });

    if (!selected.value.aligned) {
        var wanted = try ledger.wanted(workspace, paths);

        defer wanted.deinit();

        if (previous) |known| {
            const stale = try wanted.staleRows(known.paths);

            for (stale) |row| try remove(io, directory, known.paths[row]);
        } else {
            var walker = try directory.walk(allocator);
            var stale: std.ArrayList([]const u8) = .empty;

            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind != .file or !wanted.shouldRemove(entry.path, compiler.input_generation.stamp_name, true)) continue;
                try stale.append(allocator, try allocator.dupe(u8, entry.path));
            }

            for (stale.items) |path| try remove(io, directory, path);
        }
    }

    try directory.writeFile(io, .{ .sub_path = manifest_name, .data = manifest.written() });
}

/// Writes the files whose content changed on all cores; their parent directories exist already.
const Writing = struct {
    io: std.Io,
    directory: std.Io.Dir,
    files: Files,
    changed: []const u32,
    pub fn step(self: *const Writing, _: std.mem.Allocator, index: usize) !void {
        const file = self.files.at(self.changed[index]);

        try self.directory.writeFile(self.io, .{ .sub_path = file.path, .data = file.source });
    }
};

const Files = struct {
    head: []const layout.File,
    functions: []const layout.File,
    inline fn len(self: Files) usize {
        return self.head.len + self.functions.len;
    }

    inline fn at(self: Files, index: usize) layout.File {
        return if (index < self.head.len) self.head[index] else self.functions[index - self.head.len];
    }
};

fn blocks(files: []const layout.File) usize {
    return std.math.divCeil(usize, files.len, ledger.assembly.hash_batch) catch unreachable;
}

/// Projects the paths and hashes from each section in batches, without merging the sections.
const Hashing = struct {
    files: Files,
    paths: [][]const u8,
    hashes: []u64,
    pub fn step(self: *const Hashing, _: std.mem.Allocator, index: usize) !void {
        const head_blocks = blocks(self.files.head);

        if (index < head_blocks) {
            self.mark(self.files.head, 0, index);
        } else {
            self.mark(self.files.functions, self.files.head.len, index - head_blocks);
        }
    }
    fn mark(self: *const Hashing, files: []const layout.File, output: usize, index: usize) void {
        const start = index * ledger.assembly.hash_batch;
        const end = @min(start + ledger.assembly.hash_batch, files.len);

        ledger.assembly.mark(files[start..end], self.paths[output + start .. output + end], self.hashes[output + start .. output + end]);
    }
};

fn recorded(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir) !?file_manifest.Listed {
    const text = directory.readFileAlloc(io, manifest_name, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return try file_manifest.list(ledger.manifest_read, allocator, text);
}

fn remove(io: std.Io, directory: std.Io.Dir, path: []const u8) !void {
    directory.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
