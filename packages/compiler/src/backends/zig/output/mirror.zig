const std = @import("std");
const zx = @import("zx");
const ledger = @import("../output.zig");
const parallel = @import("parallel.zig");
const File = @import("../partition/placement.zig").File;
const file_manifest = @import("manifest.zig");
const manifest_name = file_manifest.name;
const stamp_name = @import("../../../inputs/generation.zig").stamp_name;

/// Publishes a generated tree while preserving unchanged files and their timestamps.
pub fn write(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, output: []const u8, files: Files) !void {
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, output);

    var directory = try cwd.openDir(io, output, .{ .iterate = true });

    defer directory.close(io);

    var frame: Frame = .{
        .io = io,
        .allocator = allocator,
        .workspace = workspace,
        .directory = directory,
        .files = files,
        .previous = try recorded(io, allocator, directory),
        .manifest = .init(allocator),
    };

    defer frame.deinit();

    try remove(io, directory, manifest_name);
    try frame.hash();
    try frame.compare();

    const changed = frame.selected.?.value.changed;

    if (changed.len != 0) {
        try frame.createParents();
        try frame.writeChanged();
    }

    if (!frame.selected.?.value.aligned) try frame.trim();
    try frame.commit();
}

const Frame = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    directory: std.Io.Dir,
    files: Files,
    previous: ?file_manifest.Listed,
    manifest: std.Io.Writer.Allocating,
    arenas: ?parallel.Arenas = null,
    hashing: Hashing = undefined,
    selected: ?ledger.Changes = null,
    fn deinit(self: *Frame) void {
        if (self.selected) |*selected| selected.deinit();
        if (self.arenas) |arenas| arenas.deinit();
    }
    fn hash(self: *Frame) !void {
        const count = self.files.len();
        const arenas = try parallel.Arenas.init(self.io, self.allocator, count);

        self.arenas = arenas;

        self.hashing = .{
            .files = self.files,
            .paths = try self.allocator.alloc([]const u8, count),
            .hashes = try self.allocator.alloc(u64, count),
        };

        const head_blocks = blocks(self.files.head);
        const batch_count = head_blocks + blocks(self.files.functions);

        try parallel.each(arenas, batch_count, &self.hashing);
        try self.manifest.writer.ensureUnusedCapacity(count * 64);
    }
    fn compare(self: *Frame) !void {
        const paths = self.hashing.paths;
        const hashes = self.hashing.hashes;
        const previous = self.previous;

        self.selected = try ledger.changes(self.workspace, .{
            .paths = paths,
            .hashes = hashes,
            .previous_paths = if (previous) |known| known.paths else &.{},
            .previous_hashes = if (previous) |known| known.hashes else &.{},
            .present = previous != null,
        });

        try file_manifest.write(ledger.manifest_write, &self.manifest.writer, paths, hashes);
    }
    fn createParents(self: *Frame) !void {
        var temporary = std.heap.ArenaAllocator.init(self.workspace);

        defer temporary.deinit();

        const allocator = temporary.allocator();

        const folders = if (comptime ledger.available) blk: {
            const entry = @import("generated_output_parents");

            const input: std.meta.Child(entry.Input) = .{
                .paths = self.hashing.paths,
                .changed = self.selected.?.value.changed,
            };

            break :blk zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| return switch (@as(anyerror, err)) {
                error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
                else => unreachable,
            };
        } else try @import("../output_seed.zig").parents(allocator, self.hashing.paths, self.selected.?.value.changed);

        for (folders) |folder| try self.directory.createDirPath(self.io, folder);
    }
    fn writeChanged(self: *Frame) !void {
        const changed = self.selected.?.value.changed;
        const output: Writer = .{ .io = self.io, .directory = self.directory };

        try parallel.each(self.arenas.?, changed.len, &Writing{ .output = output, .files = self.files, .changed = changed });
    }
    fn trim(self: *Frame) !void {
        var scratch = std.heap.ArenaAllocator.init(self.workspace);

        defer scratch.deinit();

        const temporary = scratch.allocator();
        const wanted = try @import("../output_seed.zig").wanted(temporary, self.hashing.paths);

        if (self.previous) |known| {
            var rows: std.ArrayList(u32) = .empty;

            for (known.paths, 0..) |path, row| {
                if (!wanted.contains(path)) try rows.append(temporary, @intCast(row));
            }

            for (rows.items) |row| try remove(self.io, self.directory, known.paths[row]);

            return;
        }

        var walker = try self.directory.walk(self.allocator);
        var stale: std.ArrayList([]const u8) = .empty;

        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file or std.mem.eql(u8, entry.path, stamp_name) or wanted.contains(entry.path)) continue;
            try stale.append(self.allocator, try self.allocator.dupe(u8, entry.path));
        }

        for (stale.items) |path| try remove(self.io, self.directory, path);
    }
    fn commit(self: *Frame) !void {
        try self.directory.writeFile(self.io, .{ .sub_path = manifest_name, .data = self.manifest.written() });
    }
};

const Writer = struct {
    io: std.Io,
    directory: std.Io.Dir,
    fn write(self: *const Writer, path: []const u8, body: []const u8) !void {
        try self.directory.writeFile(self.io, .{ .sub_path = path, .data = body });
    }
};

const Writing = struct {
    output: Writer,
    files: Files,
    changed: []const u32,
    pub fn step(self: *const Writing, _: std.mem.Allocator, index: usize) !void {
        const file = self.files.at(self.changed[index]);

        try self.output.write(file.path, file.source);
    }
};

pub const Files = struct {
    head: []const File,
    functions: []const File,
    inline fn len(self: Files) usize {
        return self.head.len + self.functions.len;
    }

    inline fn at(self: Files, index: usize) File {
        return if (index < self.head.len) self.head[index] else self.functions[index - self.head.len];
    }
};

fn blocks(files: []const File) usize {
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
    fn mark(self: *const Hashing, files: []const File, output: usize, index: usize) void {
        const start = index * ledger.assembly.hash_batch;
        const end = @min(start + ledger.assembly.hash_batch, files.len);

        for (files[start..end], self.paths[output + start .. output + end], self.hashes[output + start .. output + end]) |file, *path, *hash| {
            path.* = file.path;
            hash.* = zx.bytes.hash(0, file.source);
        }
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
