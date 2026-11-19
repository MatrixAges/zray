const std = @import("std");
const compiler = @import("compiler");
const layout = @import("partition/layout.zig");
const parallel = @import("parallel.zig");
const ledger = compiler.zig.file_ledger;

/// Writes the generated tree. With `partitions` set, function files are spread over that many separately
/// compiled partitions. Only changed files are rewritten and files no longer generated are removed, so an
/// output directory reused across runs keeps unchanged files byte- and timestamp-stable for Zig's cache.
pub fn write(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, output: []const u8, bundle: compiler.zig.LibraryBundle, partitions: u32) !void {
    var files: std.ArrayList(layout.File) = .empty;
    const groups = try ledger.inventory.group(allocator, bundle.modules, bundle.public_modules.len);
    const public = groups.support[groups.support.len - bundle.public_modules.len ..];
    const modules = try allocator.alloc(compiler.zig.partition.Module, public.len);

    try files.append(allocator, .{ .path = "types.zig", .source = bundle.types });

    for (bundle.public_modules, public, modules) |module, *file, *exported| {
        const name = try std.fmt.allocPrint(allocator, "{s}.zig", .{module.file.name});
        file.* = .{ .path = name, .source = module.file.source };
        exported.* = .{ .name = module.name, .file = name };

        const adapter = if (module.constant_only)
            try compiler.zig.host.reexports(allocator, "generated", module.name, &.{compiler.zig.constant_namespace})
        else
            try compiler.zig.host.bootstrapReexports(allocator, workspace, .{
                .member = module.name,
                .value_entry = module.value_entry,
                .state_entry = module.state_entry,
                .allocator_entry = module.allocator_entry,
            });

        try files.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "{s}.zig", .{module.name}), .source = adapter });
    }

    try files.appendSlice(allocator, groups.support);

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const function_files = if (partitions == 0) undefined else blk: {
        try files.append(allocator, .{ .path = "signatures.zig", .source = bundle.signatures orelse "" });

        const first = files.items.len;

        try files.resize(allocator, first + groups.functions.len);

        const original = try ledger.inventory.originals(allocator, scratch.allocator(), groups.functions, files.items[first..]);

        try files.append(allocator, .{ .path = "original/root.zig", .source = try compiler.zig.partition.indexedRoot(allocator, workspace, original, null) });

        break :blk original;
    };

    try files.append(allocator, .{ .path = "root.zig", .source = try compiler.zig.partition.rootBacked(allocator, workspace, modules, partitions != 0) });
    if (partitions == 0) try files.appendSlice(allocator, groups.functions) else try files.appendSlice(allocator, try layout.plan(io, allocator, workspace, groups.functions, function_files, groups.support, partitions));
    try mirror(io, allocator, workspace, output, files.items);
}

pub const fingerprint_name = ".zxc-inputs";
const file_manifest = @import("partition/file_manifest.zig");
const manifest_name = file_manifest.name;

/// Records the content hash of every written file in a manifest, so a later run compares hashes instead of
/// reading files back, and removes exactly the files the previous run wrote and this one does not. Without a
/// manifest the directory is walked once and every file not generated now is removed.
fn mirror(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, output: []const u8, files: []const layout.File) !void {
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, output);

    var directory = try cwd.openDir(io, output, .{ .iterate = true });

    defer directory.close(io);

    const previous = try recorded(io, allocator, directory);
    var manifest: std.Io.Writer.Allocating = .init(allocator);

    try remove(io, directory, manifest_name);

    const arenas = try parallel.Arenas.init(io, allocator, files.len);

    defer arenas.deinit();

    const hashing = Hashing{ .files = files, .hashes = try allocator.alloc(u64, files.len) };

    try parallel.each(arenas, files.len, &hashing);
    try manifest.writer.ensureUnusedCapacity(files.len * 64);

    const paths = try allocator.alloc([]const u8, files.len);

    for (files, paths) |file, *path| path.* = file.path;

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
                if (entry.kind != .file or !wanted.shouldRemove(entry.path, fingerprint_name, true)) continue;
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
    files: []const layout.File,
    changed: []const u32,
    pub fn step(self: *const Writing, _: std.mem.Allocator, index: usize) !void {
        const file = self.files[self.changed[index]];

        try self.directory.writeFile(self.io, .{ .sub_path = file.path, .data = file.source });
    }
};

/// The content hash of every file, computed on all cores.
const Hashing = struct {
    files: []const layout.File,
    hashes: []u64,
    pub fn step(self: *const Hashing, _: std.mem.Allocator, index: usize) !void {
        self.hashes[index] = compiler.bytes.hash(0, self.files[index].source);
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
