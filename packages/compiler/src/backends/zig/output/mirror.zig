const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const ledger = @import("../output.zig");
const parallel = @import("parallel.zig");
const File = @import("../partition/placement.zig").File;
const file_manifest = @import("manifest.zig");
const manifest_name = file_manifest.name;
const Failure = @import("failure.zig");
const native = if (ledger.available) @import("output_execution_abi").layouts.@"zig:output_host" else struct {};
const Hashes = if (ledger.available) native.BootstrapHashes else void;
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

    if (comptime ledger.available) {
        const entry = @import("generated_bootstrap_mirror");
        var scratch = std.heap.ArenaAllocator.init(workspace);

        defer scratch.deinit();

        const resource = scratch.allocator();

        const input: std.meta.Child(entry.Input) = .{
            .target = @ptrCast(&frame),
            .previous_paths = if (frame.previous) |previous| previous.paths else null,
            .previous_bytes = if (frame.previous) |previous| previous.paths else &.{},
            .previous_hashes = if (frame.previous) |previous| previous.hashes else &.{},
        };

        entry.executeIn(resource, &input) catch |err| {
            if (frame.failure.original) |original| return original;

            return switch (@as(anyerror, err)) {
                error.IntegerOverflow, error.Overflow => error.OutOfMemory,
                else => err,
            };
        };
    } else {
        try frame.hash();
        try frame.compare();

        const changed = frame.selected.?.value.changed;

        if (changed.len != 0) try frame.parentsSeed();
        try frame.writeChanged(changed);
        if (!frame.selected.?.value.aligned) try frame.trimSeed();
        try frame.commit();
    }
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
    hashed: Hashes = undefined,
    failure: Failure = .{},
    fn fromHandle(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
    }
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

        if (comptime ledger.available) {
            try self.hashing.publish(arenas, head_blocks, batch_count);
        } else {
            try parallel.eachSeed(arenas, batch_count, &self.hashing);
        }

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

        try self.prepareManifest();
    }
    fn prepareManifest(self: *Frame) !void {
        try file_manifest.write(ledger.manifest_write, self.workspace, &self.manifest.writer, self.hashing.paths, self.hashing.hashes);
    }
    fn parentsSeed(self: *Frame) !void {
        var temporary = std.heap.ArenaAllocator.init(self.workspace);

        defer temporary.deinit();

        const folders = try @import("../output_seed.zig").parents(temporary.allocator(), self.hashing.paths, self.selected.?.value.changed);

        for (folders) |folder| try self.directory.createDirPath(self.io, folder);
    }
    fn writeChanged(self: *Frame, changed: []const u32) !void {
        const output: Writer = .{ .io = self.io, .directory = self.directory };

        if (comptime !ledger.available) return parallel.eachSeed(self.arenas.?, changed.len, &SeedWriting{ .output = output, .files = self.files, .changed = changed });

        var columns: FileColumns = undefined;
        const view = columns.bind(self.files);

        try parallel.eachWrite(self.arenas.?, .{
            .count = changed.len,
            .hash = null,
            .render = null,
            .scan = null,
            .write = &.{ .sections = &view, .changed = changed },
        }, self.directory);
    }
    fn trimSeed(self: *Frame) !void {
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

pub fn hashBootstrapFiles(handle: *anyopaque) Failure.Error!*const Hashes {
    const frame = Frame.fromHandle(handle);

    frame.hash() catch |err| return frame.failure.save(err);
    frame.prepareManifest() catch |err| return frame.failure.save(err);

    frame.hashed = .{
        .paths = frame.hashing.paths,
        .path_bytes = frame.hashing.paths,
        .hashes = frame.hashing.hashes,
    };

    return &frame.hashed;
}

pub fn createBootstrapFolders(handle: *anyopaque, folders: []const []const u8) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    for (folders) |folder| frame.directory.createDirPath(frame.io, folder) catch |err| return frame.failure.save(err);
}

pub fn writeBootstrapChanges(handle: *anyopaque, changed: []const u32) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.writeChanged(changed) catch |err| return frame.failure.save(err);
}

pub fn listBootstrapFiles(handle: *anyopaque) Failure.Error![]const []const u8 {
    const frame = Frame.fromHandle(handle);
    var walker = frame.directory.walk(frame.allocator) catch |err| return frame.failure.save(err);

    defer {
        while (walker.inner.stack.items.len != 0) walker.leave(frame.io);

        walker.deinit();
    }

    var files: std.ArrayList([]const u8) = .empty;

    while (walker.next(frame.io) catch |err| return frame.failure.save(err)) |entry| {
        if (entry.kind != .file) continue;

        const owned = frame.allocator.dupe(u8, entry.path) catch |err| return frame.failure.save(err);

        files.append(frame.allocator, owned) catch |err| return frame.failure.save(err);
    }

    return files.items;
}

pub fn deleteBootstrapFiles(handle: *anyopaque, paths: []const []const u8) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    for (paths) |path| remove(frame.io, frame.directory, path) catch |err| return frame.failure.save(err);
}

pub fn commitBootstrapManifest(handle: *anyopaque) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.commit() catch |err| return frame.failure.save(err);
}

const Writer = struct {
    io: std.Io,
    directory: std.Io.Dir,
    fn write(self: *const Writer, path: []const u8, body: []const u8) !void {
        try self.directory.writeFile(self.io, .{ .sub_path = path, .data = body });
    }
};

const SeedWriting = struct {
    output: Writer,
    files: Files,
    changed: []const u32,
    pub fn step(self: *const SeedWriting, _: std.mem.Allocator, index: usize) !void {
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
    fn publish(self: *Hashing, arenas: parallel.Arenas, head_blocks: usize, count: usize) !void {
        var columns: FileColumns = undefined;
        const view = columns.bind(self.files);

        try parallel.eachHash(arenas, .{
            .count = count,
            .render = null,
            .scan = null,
            .write = null,
            .hash = &.{
                .sections = &view,
                .head_blocks = head_blocks,
            },
        }, .{
            .paths = self.paths,
            .hashes = self.hashes,
        });
    }
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

const FileColumns = struct {
    const Hash = if (ledger.available) std.meta.Child(@typeInfo(@FieldType(parallel.Request, "hash")).optional.child) else void;
    const View = if (ledger.available) std.meta.Child(@FieldType(Hash, "sections")) else void;
    const Source = if (ledger.available) std.meta.Child(@FieldType(View, "head")) else void;
    const fields = .{ .paths = "path", .bodies = "source" };
    const Columns = @TypeOf(memory.borrowReadFields(fields, @as([]const File, &.{})));
    head_columns: Columns,
    function_columns: Columns,
    head: Source,
    functions: Source,
    fn bind(self: *FileColumns, files: Files) View {
        self.head_columns = memory.borrowReadFields(fields, files.head);
        self.function_columns = memory.borrowReadFields(fields, files.functions);
        self.head = self.head_columns.bind(Source);
        self.functions = self.function_columns.bind(Source);

        return .{ .head = &self.head, .functions = &self.functions };
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
