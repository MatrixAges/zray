const std = @import("std");
const compiler = @import("compiler");
const source = compiler.input_snapshot;
const seed = @import("input_snapshot_seed.zig");
const seed_interfaces = compiler.source_inputs.interface_seed;
const collection = @import("source_collection.zig");
const manifest = @import("generation_manifest.zig");
const Files = @import("resident/files.zig");
const Self = @This();
const name = "input-snapshots";
const Root = struct { path: []const u8, entries: []const collection.Entry };
const Fact = source.Observation;

roots: []const Root,
facts: []const Fact,
context: []const u8,
path: []const u8,

fingerprint: ?[32]u8 = null,
/// Platform observations only: RX/ZX decides whether the previous snapshot vouches for these files.
pub fn prepare(io: std.Io, allocator: std.mem.Allocator, paths: std.mem.Allocator, files: *Files, digest: [32]u8, project: manifest.Project, text: []const u8, partitions: u32, cache: []const u8) !Self {
    const roots = try allocator.alloc(Root, project.roots.len);
    var facts: std.ArrayList(Fact) = .empty;

    for (project.roots, roots) |root, *target| {
        const entries = try collection.scan(io, allocator, paths, files, root.path, root.prefix, true);

        target.* = .{ .path = root.path, .entries = entries };

        for (entries) |entry| {
            const path = try std.fs.path.resolve(allocator, &.{ root.path, entry.relative });

            try facts.append(allocator, Fact.init(path, entry.path, entry.metadata.?));
        }
    }

    var observations: InterfaceObservations = .{
        .io = io,
        .allocator = allocator,
        .facts = &facts,
    };

    if (!try observations.include(project.interfaces)) return .{ .roots = roots, .facts = &.{}, .context = "", .path = "" };
    try compiler.source_inputs.order.sort(Fact, files.gpa, facts.items);

    const here = try std.process.currentPathAlloc(io, allocator);
    const identity = compiler.input_fingerprint.snapshot(&digest, partitions, here, text);
    const context = try allocator.dupe(u8, &std.fmt.bytesToHex(identity, .lower));
    const path = try std.fs.path.join(allocator, &.{ cache, name, context });
    const fingerprint = try reuseSaved(io, files.gpa, path, context, facts.items);

    return .{ .roots = roots, .facts = facts.items, .context = context, .path = path, .fingerprint = fingerprint };
}

fn reuseSaved(io: std.Io, workspace: std.mem.Allocator, path: []const u8, context: []const u8, facts: []const Fact) !?[32]u8 {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const allocator = scratch.allocator();
    const recorded = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(source.storage_limit)) catch return null;
    const payload = try source.open(allocator, recorded) orelse return null;
    const now = source.timestamp(std.Io.Timestamp.now(io, .real).nanoseconds);

    if (comptime source.binary_records) return source.records.reuse(payload, context, facts, now);

    return seed.reuse(allocator, payload, context, facts, now);
}

pub fn loadRoot(self: Self, io: std.Io, scratch: std.mem.Allocator, files: *Files, row: usize, documents: *std.ArrayList(collection.Document)) !void {
    const root = self.roots[row];

    try collection.load(io, scratch, files, root.path, root.entries, documents);
}

pub fn save(self: Self, io: std.Io, files: *const Files, fingerprint: [32]u8) !void {
    if (self.facts.len == 0) return;

    var scratch = std.heap.ArenaAllocator.init(files.gpa);

    defer scratch.deinit();

    const allocator = scratch.allocator();

    const bytes = if (comptime source.binary_records)
        try encode(allocator, self.context, self.facts, files, &fingerprint) orelse return
    else
        try seed.encode(allocator, self.context, self.facts, files, &fingerprint) orelse return;

    const checksum = source.seal(bytes) orelse return;
    var file = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, &checksum);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn encode(allocator: std.mem.Allocator, context: []const u8, facts: []const Fact, files: *const Files, fingerprint: *const [32]u8) !?[]const u8 {
    const records = source.records;
    const size = records.measure(facts) orelse return null;
    const payload = try allocator.alloc(u8, size);
    var writer = std.Io.Writer.fixed(payload);
    const rule = @import("generated_input_records_write");
    const memory = @import("zx").memory;
    const paths = memory.borrowTextColumn("path", facts);
    const keys = memory.borrowTextColumn("key", facts);
    var versions = SnapshotVersions{ .files = files };

    const complete = try rule.executeIn(allocator, &.{
        .writer = @ptrCast(&writer),
        .context = context,
        .digest = fingerprint,
        .count = facts.len,
        .paths = @ptrCast(&paths),
        .keys = @ptrCast(&keys),
        .versions = @ptrCast(&versions),
    });

    if (!complete) return null;

    std.debug.assert(writer.buffered().len == size);

    return payload;
}

const Version = if (source.binary_records) @import("generation_execution_abi").layouts.@"zig:generation_host".SnapshotVersion else void;

const SnapshotVersions = struct {
    files: *const Files,
    row: Version = undefined,
};

pub fn readSnapshotVersion(cache: *const anyopaque, key: []const u8) ?*const Version {
    const self: *SnapshotVersions = @ptrCast(@alignCast(@constCast(cache)));
    const version = self.files.version(key) orelse return null;
    const modified = source.timestamp(version.metadata.mtime);
    const changed = source.timestamp(version.metadata.ctime);
    const read = source.timestamp(version.read);

    self.row = .{
        .inode = version.metadata.inode,
        .size = version.metadata.size,
        .mtime_low = modified.low,
        .ctime_low = changed.low,
        .read_low = read.low,
        .mtime_high = modified.high,
        .ctime_high = changed.high,
        .read_high = read.high,
    };

    return &self.row;
}

const InterfaceObservations = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(Fact),
    fn include(self: *InterfaceObservations, declarations: []const manifest.Interface) !bool {
        const existing = self.facts.items.len;

        if (comptime !source.binary_records) {
            for (declarations) |interface| {
                const matching = seed_interfaces.find("key", interface.path, self.facts.items[0..existing]);

                if (!try self.append(matching, interface.path)) return false;
            }

            return true;
        }

        if (declarations.len == 0) return true;
        // The observed prefix stays borrowed while the interface rows are appended.
        try self.facts.ensureUnusedCapacity(self.allocator, declarations.len);

        const rule = @import("generated_observe_input_interfaces");
        const memory = @import("zx").memory;
        const paths = memory.borrowTextColumn("path", declarations);
        const keys = memory.borrowTextColumn("key", self.facts.items);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeIn(empty.allocator(), &.{
            .target = @ptrCast(self),
            .paths = @ptrCast(&paths),
            .count = declarations.len,
            .keys = @ptrCast(&keys),
            .existing = existing,
        });
    }
    fn append(self: *InterfaceObservations, matching: ?usize, path: []const u8) !bool {
        const fact = if (matching) |row|
            self.facts.items[row]

        else observed: {
            const key = try std.fs.path.resolve(self.allocator, &.{path});
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;

            break :observed Fact.init(key, key, Files.metadata(stat));
        };

        try self.facts.append(self.allocator, fact);

        return true;
    }
};

pub fn recordInputInterface(handle: *const anyopaque, path: []const u8, matching: ?u64) error{OutOfMemory}!bool {
    const self: *InterfaceObservations = @ptrCast(@alignCast(@constCast(handle)));

    return self.append(if (matching) |row| @intCast(row) else null, path);
}
