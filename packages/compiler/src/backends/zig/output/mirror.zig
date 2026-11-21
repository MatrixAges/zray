const std = @import("std");
const ledger = @import("../output.zig");
const parallel = @import("parallel.zig");
const File = @import("../partition/placement.zig").File;
const file_manifest = @import("manifest.zig");
const manifest_name = file_manifest.name;
const Failure = @import("failure.zig");
const Plan = if (ledger.available) @import("output_execution_abi").layouts.@"zig:output_host".BootstrapOutputPlan else void;
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
        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        _ = entry.executeIn(fixed.allocator(), @ptrCast(&frame)) catch |err| return frame.failure.restore(err);
    } else {
        try frame.hash();
        try frame.compare();

        const changed = frame.selected.?.value.changed;

        if (changed.len != 0) try frame.parents();
        try frame.writeChanged();
        if (!frame.selected.?.value.aligned) try frame.trim(frame.previous != null);
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
    plan: Plan = undefined,
    failure: Failure = .{},
    fn fromHandle(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
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

        try parallel.each(arenas, blocks(self.files.head) + blocks(self.files.functions), &self.hashing);
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
    fn parents(self: *Frame) !void {
        var temporary = std.heap.ArenaAllocator.init(self.workspace);

        defer temporary.deinit();

        const folders = try ledger.parents(temporary.allocator(), self.hashing.paths, self.selected.?.value.changed);

        for (folders) |folder| try self.directory.createDirPath(self.io, folder);
    }
    fn writeChanged(self: *Frame) !void {
        const changed = self.selected.?.value.changed;

        try parallel.each(self.arenas.?, changed.len, &Writing{ .io = self.io, .directory = self.directory, .files = self.files, .changed = changed });
    }
    fn trim(self: *Frame, known_paths: bool) !void {
        var wanted = try ledger.wanted(self.workspace, self.hashing.paths);

        defer wanted.deinit();

        if (known_paths) {
            const known = self.previous.?;
            const stale = try wanted.staleRows(known.paths);

            for (stale) |row| try remove(self.io, self.directory, known.paths[row]);
        } else {
            var walker = try self.directory.walk(self.allocator);
            var stale: std.ArrayList([]const u8) = .empty;

            defer walker.deinit();

            while (try walker.next(self.io)) |entry| {
                if (entry.kind != .file or !wanted.shouldRemove(entry.path, stamp_name, true)) continue;
                try stale.append(self.allocator, try self.allocator.dupe(u8, entry.path));
            }

            for (stale.items) |path| try remove(self.io, self.directory, path);
        }
    }
    fn commit(self: *Frame) !void {
        try self.directory.writeFile(self.io, .{ .sub_path = manifest_name, .data = self.manifest.written() });
    }
};

pub fn hashBootstrapFiles(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.hash() catch |err| return frame.failure.save(err);
}

pub fn compareBootstrapFiles(handle: *const anyopaque) Failure.Error!*const Plan {
    const frame = Frame.fromHandle(handle);

    frame.compare() catch |err| return frame.failure.save(err);

    const selection = frame.selected.?.value;

    frame.plan = .{
        .target = @ptrCast(frame),
        .changed = selection.changed.len,
        .aligned = selection.aligned,
        .recorded = frame.previous != null,
    };

    return &frame.plan;
}

pub fn createBootstrapParents(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.parents() catch |err| return frame.failure.save(err);
}

pub fn writeBootstrapChanges(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.writeChanged() catch |err| return frame.failure.save(err);
}

pub fn trimBootstrapFiles(handle: *const anyopaque, recorded_paths: bool) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.trim(recorded_paths) catch |err| return frame.failure.save(err);
}

pub fn commitBootstrapManifest(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.fromHandle(handle);

    frame.commit() catch |err| return frame.failure.save(err);
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
